/root/bhpanel-repo - repo.bhpanel.net's sync (github.com/wpexpertinbd/bhpanel-php, server/)

repo-sync.sh       run every 10 min by bhpanel-repo-sync.timer: downloads the newest
                   signed snapshot from the GitHub release "repo", checks it, puts it
                   live in /home/bhpmain/repo.bhpanel.net, emails info@biswashost.com
current.txt        the snapshot that is live ("name sha256")
refused.txt        the last snapshot refused (one alert email per snapshot)
lock               flock, one run at a time
work.*             temporary, removed after each run

Run by hand:  systemctl start bhpanel-repo-sync.service; journalctl -u bhpanel-repo-sync -n 20
