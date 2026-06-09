#!/usr/bin/env ruby

require "json"
require "optparse"
require "set"
require "shellwords"

options = { teams: [] }
option_parser = OptionParser.new do |opts|
  opts.on("-q", "--quiet", "Quiet mode, suppressing all output except errors")
  opts.on("-h PATH", "--gh-path", String, "Path to gh executable")
  opts.on("-t TEAM", "--team TEAM", String,
          "Team in org/slug format whose approvals should dismiss your team review-request " \
          "notifications. May be specified multiple times.") do |team|
    options[:teams] << team
  end
end
option_parser.parse!(ARGV, into: options)
quiet_mode = !!options[:quiet]
puts "Using options: #{options.inspect}" unless quiet_mode

def which(cmd)
  pathext = ENV['PATHEXT']
  exts = pathext ? pathext.split(';') : ['']
  path_env = ENV['PATH'] || ""
  path_env.split(File::PATH_SEPARATOR).each do |path|
    exts.each do |ext|
      exe = File.join(path, "#{cmd}#{ext}")
      return exe if File.executable?(exe) && !File.directory?(exe)
    end
  end
  nil
end
gh_path = options[:"gh-path"] || which("gh") || "gh"
gh_path_shell = Shellwords.escape(gh_path)

teams = options[:teams].compact.map(&:strip).reject(&:empty?).uniq
teams.each do |team|
  unless team.include?("/")
    puts "Invalid --team value #{team.inspect}; expected org/slug format."
    exit 1
  end
end

def pull_request_number_for_notification(notif)
  return unless notif["subject"]["type"] == "PullRequest"
  notif["subject"]["url"].split("/pulls/").last.to_i
end

# Fetch the current viewer login from `gh auth status` so we can exclude our
# own approvals.
viewer_login = nil
if teams.any?
  auth_status_str = `#{gh_path_shell} auth status -a -h github.com 2>&1`
  if $?.exitstatus != 0
    puts "Failed to look up viewer login via `gh auth status`; aborting."
    exit 1
  end
  match = auth_status_str.match(/Logged in to \S+ account (\S+)/)
  viewer_login = match && match[1]
  if viewer_login.nil? || viewer_login.empty?
    puts "Could not determine viewer login from `gh auth status` output; aborting."
    exit 1
  end
  puts "Authenticated as #{viewer_login}." unless quiet_mode
end

# Fetch members for each configured team. Fail closed on errors so we don't
# accidentally dismiss notifications based on incomplete team data.
team_members_by_slug = {}
teams.each do |team|
  org, slug = team.split("/", 2)
  puts "Loading members of team #{org}/#{slug}..." unless quiet_mode
  members_json_str = `#{gh_path_shell} api --paginate #{Shellwords.escape("orgs/#{org}/teams/#{slug}/members")}`
  if $?.exitstatus != 0
    puts "Failed to fetch members for team #{org}/#{slug}; aborting (requires read:org scope)."
    exit 1
  end
  members = begin
    JSON.parse(members_json_str)
  rescue => e
    puts "Failed to parse members response for team #{org}/#{slug}: #{e}"
    exit 1
  end
  unless members.is_a?(Array)
    puts "Unexpected members response for team #{org}/#{slug}: #{members.inspect}"
    exit 1
  end
  team_members_by_slug[team] = members.map { |m| m["login"] }.compact.to_set
end

puts "Loading notifications from GitHub API..." unless quiet_mode
json_str = `#{gh_path_shell} api notifications`
json = begin
  JSON.parse(json_str)
rescue => e
  puts "Failed to parse notifications API response: #{e}"
  exit 1
end
pull_notifications = json.select { |notif| notif["subject"]["type"] == "PullRequest" }
pull_numbers_by_repo_nwos = {}
pull_notifications.map do |notif|
  repo_nwo = notif["repository"]["full_name"]
  pull_numbers_by_repo_nwos[repo_nwo] ||= []
  pull_numbers_by_repo_nwos[repo_nwo] << pull_request_number_for_notification(notif)
end
pull_numbers_by_repo_nwos.each_value(&:uniq!)

repo_fields = []
repo_field_aliases_by_nwo = {}
index = 0
def pull_request_field_alias_for_number(number)
  "pull#{number}"
end

want_team_info = teams.any?
pull_extra_fields = if want_team_info
  <<~GRAPHQL
    latestReviews(first: 100) { nodes { state author { login } } }
    timelineItems(first: 100, itemTypes: REVIEW_REQUESTED_EVENT) {
      nodes {
        ... on ReviewRequestedEvent {
          requestedReviewer {
            ... on Team { slug organization { login } }
          }
        }
      }
    }
  GRAPHQL
else
  ""
end

pull_numbers_by_repo_nwos.each do |repo_nwo, pull_numbers|
  owner_login, repo_name = repo_nwo.split("/")
  pull_fields = []
  pull_numbers.each do |pull_number|
    field_alias = pull_request_field_alias_for_number(pull_number)
    pull_fields << <<~GRAPHQL
      #{field_alias}: pullRequest(number: #{pull_number}) {
        state
        #{pull_extra_fields}
      }
    GRAPHQL
  end
  field_alias = "repo#{index}"
  repo_fields << <<~GRAPHQL
    #{field_alias}: repository(owner: "#{owner_login}", name: "#{repo_name}") {
      #{pull_fields.join(" ").strip}
    }
  GRAPHQL
  repo_field_aliases_by_nwo[repo_nwo] = field_alias
  index += 1
end
gql_query = <<~GRAPHQL
  query {
    #{repo_fields.join(" ").strip}
  }
GRAPHQL
total_pull_notifs = pull_notifications.size
units = total_pull_notifs == 1 ? "notification" : "notifications"
puts "Loading info about #{total_pull_notifs} pull request #{units}..." unless quiet_mode
pull_json_str = `#{gh_path_shell} api graphql -f query='#{gql_query}'`
pull_json = begin
  JSON.parse(pull_json_str)
rescue => e
  puts "Failed to parse GraphQL API response: #{e}"
  exit 1
end

def mark_notification_as_done(notif, gh_path_shell:)
  thread_id = notif["id"]
  `#{gh_path_shell} api /notifications/threads/#{thread_id} -X DELETE -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28'`
end

# For a PR's timelineItems, return the set of configured "org/slug" team
# identifiers that have been requested for review on the PR at some point.
def configured_teams_requested_on_pull(pull_data, configured_teams)
  return [] unless pull_data.is_a?(Hash)
  events = pull_data.dig("timelineItems", "nodes") || []
  requested = events.map do |event|
    reviewer = event["requestedReviewer"]
    next nil unless reviewer.is_a?(Hash) && reviewer["slug"]
    org_login = reviewer.dig("organization", "login")
    next nil unless org_login
    "#{org_login}/#{reviewer["slug"]}"
  end.compact.to_set
  configured_teams & requested.to_a
end

puts "Processing pull request notifications..." unless quiet_mode
pull_notifications.each do |notif|
  repo_nwo = notif["repository"]["full_name"]
  repo_field_alias = repo_field_aliases_by_nwo[repo_nwo]
  next unless repo_field_alias

  pull_number = pull_request_number_for_notification(notif)
  next unless pull_number

  repo_data = pull_json["data"][repo_field_alias]
  next unless repo_data

  pull_field_alias = pull_request_field_alias_for_number(pull_number)
  pull_data = repo_data[pull_field_alias]
  next unless pull_data

  if pull_data["state"] == "MERGED"
    puts "Marking notification for merged pull request #{repo_nwo}##{pull_number} as done..." unless quiet_mode
    mark_notification_as_done(notif, gh_path_shell: gh_path_shell)
    next
  elsif pull_data["state"] == "CLOSED"
    puts "Marking notification for closed pull request #{repo_nwo}##{pull_number} as done..." unless quiet_mode
    mark_notification_as_done(notif, gh_path_shell: gh_path_shell)
    next
  end

  next unless want_team_info
  next unless notif["reason"] == "review_requested"

  matched_teams = configured_teams_requested_on_pull(pull_data, teams)
  next if matched_teams.empty?

  approver_logins = (pull_data.dig("latestReviews", "nodes") || []).select do |review|
    review["state"] == "APPROVED"
  end.map { |review| review.dig("author", "login") }.compact.reject { |login| login == viewer_login }
  next if approver_logins.empty?

  dismissed = false
  matched_teams.each do |team|
    members = team_members_by_slug[team] || Set.new
    approving_teammate = approver_logins.find { |login| members.include?(login) }
    next unless approving_teammate
    puts "Marking notification for #{repo_nwo}##{pull_number} as done: teammate " \
         "#{approving_teammate} approved via configured team #{team}." unless quiet_mode
    mark_notification_as_done(notif, gh_path_shell: gh_path_shell)
    dismissed = true
    break
  end
  next if dismissed
end
puts "Done!" unless quiet_mode
