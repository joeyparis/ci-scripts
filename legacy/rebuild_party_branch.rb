#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

def shell(cmd)
  puts "+ #{cmd}"
  success = system(cmd)
  raise "Command failed: #{cmd}" unless success
end

def bitbucketApiGet(url, username, app_password)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req.basic_auth(username, app_password)

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(req)
  end

  unless res.is_a?(Net::HTTPSuccess)
    raise "Bitbucket API error #{res.code}: #{res.body}"
  end

  JSON.parse(res.body)
end

def fetchOpenPrs(workspace, repo_slug, username, app_password)
  # All open PRs, any base branch
  query = 'state="OPEN"'
  encoded_q = URI.encode_www_form_component(query)

  url = "https://api.bitbucket.org/2.0/repositories/#{workspace}/#{repo_slug}/pullrequests?q=#{encoded_q}"

  prs = []
  loop do
    body = bitbucketApiGet(url, username, app_password)
    values = body['values'] || []
    prs.concat(values)

    next_link = body['next']
    break unless next_link

    url = next_link
  end

  prs
end

def partyBranchNameForBase(base_branch_name)
  # Deterministic convention: party/<base>-qa
  # e.g. develop -> party/develop-qa
  #      release/2025-11-01 -> party/release/2025-11-01-qa
  "party/#{base_branch_name}-qa"
end

workspace    = ENV.fetch('BITBUCKET_WORKSPACE')
repo_slug    = ENV.fetch('BITBUCKET_REPO_SLUG')
username     = ENV.fetch('BB_USERNAME')
app_password = ENV.fetch('BB_APP_PASSWORD')

puts "Workspace:    #{workspace}"
puts "Repo slug:    #{repo_slug}"

prs = fetchOpenPrs(workspace, repo_slug, username, app_password)

if prs.empty?
  puts "No open PRs; nothing to do."
  exit 0
end

pr_ids = prs.map { |pr| pr['id'] }
puts "Found #{prs.size} open PR(s): #{pr_ids.join(', ')}"

# Group PRs by destination (base) branch
prs_by_base = Hash.new { |h, k| h[k] = [] }
branch_to_pr_id = {}

prs.each do |pr|
  dest_branch = pr.dig('destination', 'branch', 'name')
  src_branch  = pr.dig('source', 'branch', 'name')
  next unless dest_branch && src_branch

  prs_by_base[dest_branch] << pr
  branch_to_pr_id[src_branch] = pr['id']
end

if prs_by_base.empty?
  puts "No PRs with valid source/destination branches; nothing to do."
  exit 0
end

target_bases = prs_by_base.keys
puts "Target base branches for party rebuild: #{target_bases.join(', ')}"

# Fetch all branches once
shell("git fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune")

target_bases.each do |base_branch_name|
  prs_for_base = prs_by_base[base_branch_name]
  party_branch_name = partyBranchNameForBase(base_branch_name)

  head_branches = prs_for_base.map { |pr| pr.dig('source', 'branch', 'name') }.compact.uniq

  puts "--------------------------------------------------"
  puts "Rebuilding party branch for base: #{base_branch_name}"
  puts "  Party branch: #{party_branch_name}"
  puts "  PRs: #{prs_for_base.map { |pr| pr['id'] }.join(', ')}"
  puts "--------------------------------------------------"

  # Minimal debug: show working tree status before we wipe it
  shell("git status --short || true")

  # Ensure a clean working tree for this base branch
  shell('git reset --hard')
  shell('git clean -fd')

  # checkout/reset party branch from origin/<base>
  shell("git checkout -B #{party_branch_name} origin/#{base_branch_name}")

  # Merge each head branch into the party branch, skipping conflicts
  conflicting_branches = []

  head_branches.each do |head_branch|
    merge_ref = "origin/#{head_branch}"
    pr_id     = branch_to_pr_id[head_branch]

    label = pr_id ? "PR ##{pr_id} (#{merge_ref})" : merge_ref
    puts "Merging #{label} into #{party_branch_name}..."

    begin
      shell("git merge --no-ff --no-edit #{merge_ref}")
    rescue => e
      warn "Merge conflict when merging #{label}: #{e.message}"
      warn "Skipping #{label} for this run due to conflict."

      # Do not blow up the whole pipeline; abort the merge and continue
      system('git merge --abort')
      conflicting_branches << label
    end
  end

  if conflicting_branches.any?
    puts '=================================================='
    puts "WARNING: The following PR branches were SKIPPED"
    puts "         from #{party_branch_name} due to merge conflicts:"
    conflicting_branches.each do |label|
      puts "  - #{label}"
    end
    puts '=================================================='
  end

  # Force push party branch for this base
  shell("git push origin #{party_branch_name} --force")
end
