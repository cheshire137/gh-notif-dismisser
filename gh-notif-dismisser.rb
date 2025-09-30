#!/usr/bin/env ruby

require "json"
require "optparse"

options = {}
option_parser = OptionParser.new do |opts|
  opts.on("-q", "--quiet", "Quiet mode, suppressing all output except errors")
  opts.on("-h PATH", "--gh-path", String, "Path to gh executable")
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
def pull_request_number_for_notification(notif)
  return unless notif["subject"]["type"] == "PullRequest"
  notif["subject"]["url"].split("/pulls/").last.to_i
end
puts "Loading notifications from GitHub API..." unless quiet_mode
json_str = `#{gh_path} api notifications`
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
repo_fields = []
repo_field_aliases_by_nwo = {}
index = 0
def pull_request_field_alias_for_number(number)
  "pull#{number}"
end
pull_numbers_by_repo_nwos.each do |repo_nwo, pull_numbers|
  owner_login, repo_name = repo_nwo.split("/")
  pull_fields = []
  pull_numbers.each do |pull_number|
    field_alias = pull_request_field_alias_for_number(pull_number)
    pull_fields << <<~GRAPHQL
      #{field_alias}: pullRequest(number: #{pull_number}) { state }
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
pull_json_str = `#{gh_path} api graphql -f query='#{gql_query}'`
pull_json = begin
  JSON.parse(pull_json_str)
rescue => e
  puts "Failed to parse GraphQL API response: #{e}"
  exit 1
end
puts "Looking for merged PRs with notifications..."
def mark_notification_as_done(notif)
  thread_id = notif["id"]
  `#{gh_path} api /notifications/threads/#{thread_id} -X DELETE -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28'`
end
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
    mark_notification_as_done(notif)
  elsif pull_data["state"] == "CLOSED"
    puts "Marking notification for closed pull request #{repo_nwo}##{pull_number} as done..." unless quiet_mode
    mark_notification_as_done(notif)
  end
end
puts "Done!" unless quiet_mode
