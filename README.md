# gh-notif-dismisser

This uses [`gh`](https://cli.github.com/) to interact with the GitHub API via a Ruby script. It will mark as done any
notification that's for a pull request that's now merged or closed.

## Sample cron setup

Create a directory to hold output logs so you can see if errors occur. For example:

```sh
mkdir ~/Documents/gh-notif/dismisser-logs
```

To get a GitHub token to authenticate with, try running `gh auth refresh -s repo` and go through the interactive
authentication flow. Once complete, you can run `gh auth token` to get your GitHub API token.

Then you can add configuration like the following to your crontab to run the script automatically on a regular schedule:

```cron
# At every 10th minute past every hour from 8 through 17 on every day-of-week from Monday through Friday:
*/10 8-17 * * 1-5 echo "YOUR_TOKEN_HERE" | /path/to/gh auth login --with-token && /path/to/gh-notif-dismisser.rb -h "/path/to/gh" >/path/to/gh-notif-dismisser-logs/stdout.log 2>/path/to/gh-notif-dismisser-logs/stderr.log
```

To view logs after the script has run at least once, you can run:

```sh
tail -f ~/Documents/gh-notif-dismisser-logs/*
```

## References

- [Crontab Guru](https://crontab.guru/#*/10_8-17_*_*_1-5)
- [REST API endpoints for notifications](https://docs.github.com/rest/activity/notifications?apiVersion=2022-11-28)
