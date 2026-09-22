# fim-readonly-guard.ps1
# PreToolUse hook for the FIM (Functional Integrity Manager) subagent's Bash tool.
# Reads the hook JSON on stdin, extracts tool_input.command, and BLOCKS (exit 2) commands
# that would modify source files, git state, packages, live infrastructure, or system state.
# FIM is a read-only auditor: it may inspect and verify, never change.
#
#   exit 0 = no opinion (normal permission flow continues)
#   exit 2 = blocked; the reason is shown to FIM so it picks a non-mutating alternative
#            or records the check under "Not checked" instead of retrying.
#
# Invoked by the agent frontmatter as:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file>
# Deliberately conservative: a rare false positive costs one denied call; a false negative
# would break the read-only promise. Any internal error fails CLOSED (denies).

$ErrorActionPreference = 'Stop'

function Deny([string]$reason) {
    $safe = ($reason -replace '[\\"]', '') -replace '[\r\n]+', ' '
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"FIM read-only guard: ' + $safe + '"}}'
    [Console]::Out.WriteLine($json)
    [Console]::Error.WriteLine('FIM READ-ONLY GUARD BLOCKED THIS COMMAND.')
    [Console]::Error.WriteLine('Reason: ' + $safe)
    [Console]::Error.WriteLine('FIM is a read-only auditor. Do NOT retry a variant that performs the same mutation. Use the Read/Grep/Glob tools, or a check-only form (tsc --noEmit, cargo check, ruff check without --fix, git status/log/diff/show, make -n). If a verification is impossible without mutating something, record it under "Not checked" with the exact command the caller could run, then move on.')
    exit 2
}

function Has([string]$text, [string]$pattern) {
    return [regex]::IsMatch($text, $pattern)
}

$cmd = ''
try {
    $raw = [Console]::In.ReadToEnd()
    $j = $raw | ConvertFrom-Json
    if ($null -ne $j.tool_input -and $null -ne $j.tool_input.command) { $cmd = [string]$j.tool_input.command }
} catch {
    $cmd = ''
}
if ([string]::IsNullOrWhiteSpace($cmd)) {
    Deny 'could not read tool_input.command from the hook input, so the command cannot be proven safe (fail closed)'
}

try {
    # ---- normalize -------------------------------------------------------------------
    # flat     : whole command on one line (heredoc bodies included)
    # stripped : quoted strings blanked, so grep patterns / messages do not trigger false positives
    # noredir  : harmless redirections (to /dev/null, fd-to-fd) removed before the redirect check
    $flat     = $cmd -replace '[\r\n]+', ' '
    $stripped = [regex]::Replace($flat, "'[^']*'", "''")
    $stripped = [regex]::Replace($stripped, '"(?:[^"\\]|\\.)*"', '""')
    $noredir  = $stripped -replace '\d*>{1,2}\s*/dev/null', ''
    $noredir  = $noredir  -replace '&>{1,2}\s*/dev/null', ''
    $noredir  = $noredir  -replace '\d*>&\d+', ''
    $noredir  = $noredir  -replace '\d*>&-', ''

    $SEP = '(?:^|[\s;&|(])'   # token boundary: start, whitespace, or shell separator (NOT "-", so --rm does not match rm)
    $END = '(?:\s|$)'

    # ---- pure version/help invocations are always allowed -----------------------------
    $segs = [regex]::Split($noredir, '&&|\|\||;|\|')
    $allVersion = $true
    foreach ($seg in $segs) {
        $t = $seg.Trim()
        if ($t.Length -eq 0) { continue }
        if (-not (Has $t '^\S+(?:\s+-C\s+\S+)?\s+(?:--version|-version|-V|-v|version|--help|-h|help|-help)$')) { $allVersion = $false; break }
    }
    if ($allVersion) { exit 0 }

    # ---- 1. output redirection to a file --------------------------------------------
    if (Has $noredir '>') {
        Deny 'output redirection (> or >>) writes to a file; only redirection to /dev/null or between file descriptors is allowed'
    }

    # ---- 2. simple deny rules: pattern matched against $noredir ------------------------
    $rules = @(
        @('file or permission mutation command (rm mv cp mkdir touch tee chmod install sudo ...)',
          ($SEP + '(?:rm|rmdir|unlink|shred|mv|cp|dd|tee|truncate|chmod|chown|chgrp|chattr|ln|mkdir|touch|install|mkfs|mount|umount|del|erase|rd|md|move|copy|ren|rename|xcopy|robocopy|attrib|icacls|takeown|sudo|doas|runas|su|sponge)' + $END)),
        @('find -delete / -fprint / -fls writes or deletes files',
          '(?:^|\s)(?:-delete|-fprint0?|-fls|-fprintf)(?:\s|$)'),
        @('sed -i edits files in place; use sed -n or the Read tool',
          ($SEP + 'sed(?:\s+\S+)*\s+(?:-[a-zA-Z]*i[a-zA-Z]*|--in-place)')),
        @('perl -i edits files in place',
          ($SEP + 'perl(?:\s+-[a-zA-Z0-9]*)*\s+-[a-zA-Z0-9]*i')),
        @('awk -i inplace edits files in place',
          ($SEP + 'g?awk(?:\s+\S+)*\s+-i\s+inplace')),
        @('text editors can modify files',
          ($SEP + '(?:ed|ex|vi|vim|nvim|nano|pico|emacs|micro|joe|notepad|notepad\+\+|code|subl|gedit)' + $END)),
        @('package manager write, publish, cache, or dev-server command (npm/pnpm/yarn/bun)',
          ($SEP + '(?:npm|pnpm|yarn|bun)\s+(?:i|add|remove|rm|r|un|uninstall|unlink|link|update|up|upgrade|publish|ci|init|create|prune|dedupe|ddp|rebuild|rb|set|set-script|pkg|version|deprecate|dist-tag|owner|access|login|logout|adduser|token|hook|star|unstar|cache|dlx|x|import|patch|patch-commit|store|setup|self-update|start|dev|serve|preview|watch)' + $END)),
        @('bare yarn/bun installs dependencies',
          ($SEP + '(?:yarn|bun)\s*(?:$|[;&|)])')),
        @('pip/pipx write command',
          ($SEP + '(?:pip|pip3|pipx|uv\s+pip)\s+(?:uninstall|download|wheel|cache|config|inject|reinstall|ensurepath|upgrade|upgrade-all|run)' + $END)),
        @('uv write command',
          ($SEP + 'uv\s+(?:add|remove|sync|lock|venv|init|build|publish|tool|python|self|cache|run)' + $END)),
        @('poetry write command',
          ($SEP + 'poetry\s+(?:add|remove|update|lock|build|publish|env|self|cache|init|new|source|run|shell)' + $END)),
        @('conda write command',
          ($SEP + '(?:conda|mamba|micromamba)\s+(?:remove|uninstall|update|create|env|clean|init|config|rename|run)' + $END)),
        @('pipenv write command',
          ($SEP + 'pipenv\s+(?:uninstall|update|lock|sync|clean|--rm|run|shell)' + $END)),
        @('python environment or packaging write command',
          ($SEP + '(?:virtualenv' + $END + '|python[0-9.]*\s+-m\s+(?:venv|pip\s+(?:uninstall|download|wheel|cache|config)|ensurepip|compileall|build|twine)' + $END + ')')),
        @('cargo write, publish, or run command (cargo check/clippy/test/build are allowed)',
          ($SEP + 'cargo\s+(?:uninstall|add|remove|rm|publish|update|new|init|clean|generate-lockfile|vendor|yank|owner|login|logout|fix|package|run|r)' + $END)),
        @('rustup modifies the toolchain',
          ($SEP + 'rustup\s+(?:install|uninstall|update|default|toolchain|target|component|self|override|set)' + $END)),
        @('go write or run command (go vet/build/test/list are allowed)',
          ($SEP + 'go\s+(?:get|clean|fix|generate|run|telemetry|env\s+-w|mod\s+(?:tidy|download|vendor|edit|init)|work\s+(?:init|use|sync|edit))' + $END)),
        @('ruby/php package manager write command',
          ($SEP + '(?:gem\s+(?:uninstall|update|push|cleanup|yank|owner)|bundle\s+(?:update|add|remove|clean|pristine|lock|init|config|exec)|composer\s+(?:update|require|remove|create-project|dump-autoload|dumpautoload|clear-cache|clearcache|self-update|selfupdate|init|config|run|run-script))' + $END)),
        @('system package manager write command',
          ($SEP + '(?:apt|apt-get|aptitude|dnf|yum|pacman|zypper|apk|brew|choco|winget|scoop|snap|flatpak|nix-env|nix|port|emerge|pkg)\s+(?:remove|uninstall|purge|upgrade|update|autoremove|autoclean|clean|dist-upgrade|full-upgrade|add|del|tap|untap|link|unlink|pin|unpin|cleanup|refresh|source|reinstall|reset|bucket|hold|unhold|profile|develop|shell|run|build|-S[a-zA-Z]*|-R[a-zA-Z]*|-U[a-zA-Z]*|-D[a-zA-Z]*|--sync|--remove|--upgrade|-i|-e|-u)' + $END)),
        @('dotnet/nuget/maven/gradle write, publish, or run command',
          ($SEP + '(?:dotnet\s+(?:add|remove|restore|publish|pack|nuget|tool|new|clean|workload|user-secrets|dev-certs|ef|run|watch)|nuget\s+(?:push|delete|update|restore|sources|install)|mvn\s+(?:\S+\s+)*(?:install|deploy|clean|package|release\S*|versions:\S+|archetype:generate)|(?:gradle|gradlew)(?:\s+\S+)*\s+(?:publish\S*|install\S*|clean|wrapper|init|uploadArchives|bootRun|run))' + $END)),
        @('build orchestrator can generate or modify files; inspect its config files instead',
          ($SEP + '(?:cmake|ninja|meson|msbuild|bazel|buck|buck2|scons|ant|rake|gulp|grunt|lerna|nx|turbo|rush|moon)' + $END)),
        @('toolchain manager modifies the environment',
          ($SEP + '(?:nvm|pyenv|rbenv|asdf|volta|fnm|sdk|corepack|direnv|mise|proto)\s+(?:install|uninstall|use|global|local|alias|unalias|default|pin|plugin|reshim|shell|enable|disable|prepare|allow|deny|set|activate|trust|self-update|upgrade|update|exec|x|run)' + $END)),
        @('fix/write flag would modify files; run the check-only form',
          '(?:^|\s)(?:--fix|--fix-only|--write|--apply|--apply-unsafe|--unsafe-fixes|--autocorrect(?:-all)?|--in-place|--fix-type|--save-exact|--save|--save-dev)(?:[\s=]|$)'),
        @('formatter -w writes files; run without -w or with --check / -l',
          ($SEP + '(?:gofmt|goimports|shfmt|prettier)(?:\s+\S+)*\s+-w' + $END)),
        @('formatter -i writes files in place',
          ($SEP + '(?:clang-format|autopep8|yapf|clang-tidy)(?:\s+\S+)*\s+-i' + $END)),
        @('rubocop -a/-A autocorrects files',
          ($SEP + 'rubocop(?:\s+\S+)*\s+-[aA]' + $END)),
        @('container command that builds, runs, or modifies containers/images (docker ps/images/inspect/version are allowed)',
          ($SEP + '(?:docker(?:\s+compose)?|docker-compose|podman|nerdctl)\s+(?:build|run|up|down|push|pull|rm|rmi|exec|create|start|stop|restart|kill|commit|cp|import|load|save|login|logout|attach|pause|unpause|rename|update|wait|export|buildx|swarm|service|stack|node|secret|system\s+prune|volume\s+(?:create|rm|prune)|network\s+(?:create|rm|prune|connect|disconnect)|image\s+(?:rm|prune|build|push|pull|tag|import|load|save)|container\s+(?:rm|prune|create|start|stop|kill|restart|exec|cp|commit|rename|update|pause|unpause)|context\s+(?:create|rm|use|update))' + $END)),
        @('cloud, cluster, deployment, or remote-shell CLI; FIM never touches live infrastructure or remote hosts',
          ($SEP + '(?:kubectl|oc|helm|terraform|tofu|pulumi|cdk|cdktf|sam|serverless|sls|aws|gcloud|gsutil|az|flyctl|fly|vercel|netlify|heroku|wrangler|firebase|supabase|railway|doctl|linode-cli|oci|ibmcloud|ansible|ansible-playbook|vagrant|packer|nomad|consul|vault|k3d|kind|minikube|eksctl|argocd|flux|istioctl|linkerd|skaffold|tilt|garden|okteto|render|dokku|cf|kamal|capistrano|cap|fab|fabric|ssh|scp|sftp|rsync|ftp|telnet|nc|ncat|netcat|socat|mosh)' + $END)),
        @('download command',
          ($SEP + '(?:wget|aria2c|axel|Invoke-WebRequest|iwr|Invoke-RestMethod|irm|Start-BitsTransfer|bitsadmin)' + $END)),
        @('certutil download or store modification',
          ($SEP + 'certutil(?:\s+\S+)*\s+-(?:urlcache|decode|encode|addstore|delstore)')),
        @('HTTP write request',
          ($SEP + '(?:http|https|xh)\s+(?:-\S+\s+)*(?:POST|PUT|PATCH|DELETE)' + $END)),
        @('process, service, scheduling, registry, disk, user, or firewall command',
          ($SEP + '(?:kill|killall|pkill|taskkill|shutdown|reboot|halt|poweroff|telinit|systemctl|launchctl|setx|schtasks|crontab|bcdedit|diskpart|fdisk|parted|gdisk|sfdisk|wipefs|swapon|swapoff|sysctl|ufw|iptables|ip6tables|nft|firewall-cmd|netsh|hostnamectl|timedatectl|useradd|userdel|usermod|groupadd|groupdel|passwd|chpasswd|visudo|update-alternatives|ldconfig|modprobe|insmod|rmmod|dism|sfc|powercfg|wmic|gpupdate|gpedit|regedit|reg|Start-Service|Stop-Service|Restart-Service|Set-Service|New-Service|Stop-Process|Start-Process|Stop-Computer|Restart-Computer)' + $END)),
        @('service, network, or user modification command',
          ($SEP + '(?:sc\s+(?:create|delete|config|start|stop|pause|continue|failure|sdset)|net\s+(?:start|stop|user|localgroup|share|use|config|accounts|file|time)|service\s+\S+\s+(?:start|stop|restart|reload|enable|disable)|route\s+(?:add|del|delete|change|flush|-p)|ifconfig\s+\S+\s+(?:up|down|add|del|inet|netmask|mtu|hw)|ip\s+(?:link|addr|address|route|rule|neigh|netns)\s+(?:add|del|delete|set|flush|change|replace))' + $END)),
        @('nested shell -c hides the real command from the guard',
          ($SEP + '(?:bash|sh|zsh|dash|ksh|fish|busybox)(?:\s+-[a-zA-Z]*)*\s+-[a-zA-Z]*c')),
        @('powershell/cmd/wsl subshells cannot be inspected by the guard; use Git Bash equivalents (command -v, ls, cat)',
          ($SEP + '(?:powershell|pwsh|powershell\.exe|pwsh\.exe|cmd|cmd\.exe|wsl|wsl\.exe|osascript|expect)' + $END)),
        @('eval/exec/source run code the guard cannot inspect',
          ($SEP + '(?:eval|exec|source)\s|(?:^|[;&|(]\s*)\.\s')),
        @('running a shell script executes arbitrary commands; read the script instead',
          ($SEP + '(?:bash|sh|zsh|dash|ksh|fish)\s+(?:\S+\s+)*?\S*\.(?:sh|bash|zsh|fish|bats)' + $END)),
        @('executing a script or binary directly; read it or run its documented check-only tool instead',
          '(?:^|[;&|(]\s*|&&\s*|\|\|\s*)\s*(?:\./|/|~/|[A-Za-z]:/)?\S*\.(?:sh|bash|zsh|fish|ps1|bat|cmd|vbs|wsf|msi|exe|com|scr|pif|reg|jar|app|run|bin)(?:\s|$)'),
        @('background, watch, or long-running process control',
          ($SEP + '(?:nohup|setsid|disown|screen|tmux|watch|sleep|inotifywait|fswatch|entr|nodemon|ts-node-dev|tsx\s+watch|node\s+--watch|supervisord|pm2|forever)' + $END)),
        @('trailing & starts a background process',
          '(?:^|[^&])&\s*(?:$|[;)])'),
        @('watch/serve mode never terminates',
          '(?:^|\s)(?:--watch(?:All)?|--watch-path|--hot|--live-reload|--serve)(?:[\s=]|$)'),
        @('watch mode never terminates',
          ($SEP + '(?:tsc|jest|vitest|mocha|karma|webpack|rollup|esbuild|parcel|swc|babel|sass|less|postcss|tailwindcss|ng|cargo\s+watch)(?:\s+\S+)*\s+(?:-w|--watch)' + $END)),
        @('starting a server or dev process never terminates and may write files',
          ($SEP + '(?:serve|http-server|live-server|json-server|webpack-dev-server|uvicorn|gunicorn|hypercorn|daphne|waitress-serve|flask\s+run|django-admin\s+runserver|manage\.py\s+runserver|rails\s+s(?:erver)?|php\s+-S|php\s+artisan\s+serve|python[0-9.]*\s+-m\s+(?:http\.server|SimpleHTTPServer|flask\s+run|uvicorn|gunicorn)|vite(?:\s+(?:dev|serve|preview))?|next\s+(?:dev|start)|nuxt(?:\s+(?:dev|start|preview))?|astro\s+(?:dev|preview)|remix\s+dev|ng\s+serve|expo\s+start|react-native\s+start|storybook\s+dev|hugo\s+server|jekyll\s+serve|mkdocs\s+serve|dotnet\s+run|spring-boot:run|air|reflex|watchexec)' + $END)),
        @('tar extraction writes files (tar -t to list is allowed)',
          ($SEP + 'tar(?:\s+-?[a-zA-Z]*x[a-zA-Z]*|(?:\s+\S+)*\s+--extract)' + $END)),
        @('piping into a shell/interpreter/clipboard/mailer executes or exfiltrates content',
          '\|\s*(?:bash|sh|zsh|dash|ksh|fish|python[0-9.]*|node|ruby|perl|php|pwsh|powershell|cmd|clip|xclip|xsel|pbcopy|lp|lpr|wall|write|mail|sendmail|msmtp)(?:\s|$)')
    )
    foreach ($r in $rules) {
        if (Has $noredir $r[1]) { Deny $r[0] }
    }

    # ---- 3. package-manager scripts that start servers, watch, deploy, or rewrite files ----
    if (Has $noredir ($SEP + '(?:npm|pnpm|yarn|bun)\s+run(?:-script)?\s+(?:\S*:)?(?:dev|start|serve|preview|watch|deploy|publish|release|clean|format|fmt|fix|migrate|seed|generate|gen|codegen|prepare|postinstall|install|write)' + $END)) {
        Deny 'package script that starts a server, watches, deploys, migrates, or rewrites files'
    }

    # ---- 4. git: allowlist of read-only subcommands; anything else is denied -----------
    if (Has $noredir ($SEP + 'git' + $END)) {
        $gitPre   = 'git(?:\s+(?:-C\s+\S+|-c\s+\S+|--[a-z-]+(?:=\S*)?|-[a-zA-Z]+))*'
        $readOnly = '^' + $gitPre + '\s+(?:status|log|diff|show|blame|grep|ls-files|ls-tree|ls-remote|rev-parse|rev-list|describe|cat-file|shortlog|whatchanged|name-rev|merge-base|count-objects|var|version|--version|help|check-ignore|check-attr|check-mailmap|for-each-ref|show-ref|diff-tree|diff-index|diff-files|verify-pack|verify-commit|verify-tag|show-branch|cherry|range-diff|bugreport|diagnose|hash-object|stripspace|column|interpret-trailers)(?:\s+\S+)*$'
        $listing  = '^' + $gitPre + '\s+(?:' +
            'stash\s+(?:list|show)(?:\s+\S+)*' +
            '|tag(?:\s+(?:-l\s+\S+|-l|--list\s+\S+|--list|-n\d*|--contains(?:\s+\S+)?|--no-contains(?:\s+\S+)?|--points-at\s+\S+|--sort=\S+|--format=\S*|--merged(?:\s+\S+)?|--no-merged(?:\s+\S+)?|''''|""))*' +
            '|branch(?:\s+(?:-a|-r|-v|-vv|-l\s+\S+|-l|--list\s+\S+|--list|--all|--remotes|--show-current|--contains(?:\s+\S+)?|--no-contains(?:\s+\S+)?|--merged(?:\s+\S+)?|--no-merged(?:\s+\S+)?|--points-at\s+\S+|--sort=\S+|--format=\S*|''''|""))*' +
            '|remote(?:\s+(?:-v|--verbose|show(?:\s+\S+)*|get-url(?:\s+\S+)*))*' +
            '|config\s+(?:--global\s+|--local\s+|--system\s+|--worktree\s+)?(?:--get|--get-all|--get-regexp|--list|-l|--show-origin|--show-scope)(?:\s+\S+)*' +
            '|reflog(?:\s+show(?:\s+\S+)*)?' +
            '|worktree\s+list(?:\s+\S+)*' +
            '|submodule\s+status(?:\s+\S+)*' +
            '|notes\s+(?:list|show)(?:\s+\S+)*' +
            '|lfs\s+(?:ls-files|status|env|version)(?:\s+\S+)*' +
            '|sparse-checkout\s+list' +
            ')$'
        $ms = [regex]::Matches($noredir, $SEP + '(' + $gitPre + '\s+[^\s&|;)]+(?:\s+[^\s&|;)]+)*)')
        foreach ($m in $ms) {
            $inv = $m.Groups[1].Value
            if (Has $inv '(?:^|\s)--output(?:[\s=]|$)') { Deny 'git --output writes a file' }
            if (Has $inv $readOnly) { continue }
            if (Has $inv $listing)  { continue }
            Deny 'git command is not in the read-only allowlist (allowed: status log diff show blame grep ls-files rev-parse describe cat-file, stash list/show, tag/branch/remote listing, config --get/--list)'
        }
    }

    # ---- 5. conditional rules (tool present AND its check-only flag absent) -------------
    if ((Has $noredir ($SEP + 'make' + $END)) -and -not (Has $noredir '(?:^|\s)(?:-n|--dry-run|--just-print|--recon|-q|--question|-p|--print-data-base)(?:\s|$)')) {
        Deny 'make runs arbitrary recipes; only make -n (dry run) or make -q is allowed'
    }
    if ((Has $noredir ($SEP + '(?:black|isort)' + $END)) -and -not (Has $noredir '(?:^|\s)(?:--check|--diff|-d|--check-only)(?:\s|$)')) {
        Deny 'black/isort write files by default; use --check or --diff'
    }
    if ((Has $noredir ($SEP + '(?:rustfmt|cargo\s+fmt)' + $END)) -and -not (Has $noredir '(?:^|\s)--check(?:\s|$)')) {
        Deny 'rustfmt/cargo fmt write files by default; use --check'
    }
    # tsc emits .js next to its sources unless told not to. A project whose tsconfig
    # sets "noEmit": true would write nothing, but the guard cannot see the tsconfig,
    # and a rare denied call is cheaper than a broken read-only promise.
    # TypeScript flags are case-insensitive, hence (?i).
    if ((Has $noredir ($SEP + '(?:tsc|tsgo)' + $END)) -and -not (Has $noredir '(?i)(?:^|\s)(?:--noEmit|--dry)(?:\s|$)')) {
        Deny 'tsc writes .js files by default; use tsc --noEmit'
    }
    if ((Has $noredir ($SEP + 'ruff\s+format' + $END)) -and -not (Has $noredir '(?:^|\s)(?:--check|--diff)(?:\s|$)')) {
        Deny 'ruff format writes files by default; use ruff format --check or --diff'
    }
    if ((Has $noredir ($SEP + '(?:deno\s+fmt|dart\s+format|mix\s+format|dotnet\s+format|swiftformat|swift-format\s+format|php-cs-fixer\s+fix|pint|stylua|taplo\s+fmt|nixfmt|alejandra|zig\s+fmt|elm-format|ormolu|fourmolu|scalafmt|ktlint\s+-F|google-java-format)' + $END)) -and -not (Has $noredir '(?:^|\s)(?:--check|--check-formatted|--verify-no-changes|--lint|--dry-run|--test|--output[= ]none|-o\s+none|--validate|--set-exit-if-changed|--mode[= ]check|--in-place=false|--replace=false|--check-only)(?:\s|$)')) {
        Deny 'this formatter writes files by default; use its check-only flag'
    }
    if ((Has $noredir ($SEP + 'curl' + $END)) -and (Has $noredir '(?:^|\s)(?:-X\s*(?:POST|PUT|PATCH|DELETE)|--request[\s=]*(?:POST|PUT|PATCH|DELETE)|-d|--data(?:-[a-z]+)?|-F|--form|-T|--upload-file|-o|-O|--output|--remote-name|-J|--remote-header-name|-K|--config|--create-dirs|-c|--cookie-jar|--trace(?:-[a-z]+)?|--dump-header|-D)(?:[\s=]|$)')) {
        Deny 'curl with a writing, uploading, or downloading option (plain GET with -s/-I/-L is allowed)'
    }
    if ((Has $noredir ($SEP + '(?:unzip|zip|gzip|gunzip|bzip2|bunzip2|xz|unxz|zstd|unzstd|7z|7za|7zr|unrar|rar|cpio|cabextract|Expand-Archive|Compress-Archive)' + $END)) -and -not (Has $noredir ($SEP + '(?:unzip\s+-[lvztp]|7z\s+[lt]|unrar\s+[lv]|gzip\s+-[a-z]*[lt]|xz\s+-[a-z]*[lt]|zstd\s+-[a-z]*l|cpio\s+-[a-z]*t)'))) {
        Deny 'archive extraction or compression creates files (listing with unzip -l, 7z l, tar -t is allowed)'
    }

    # ---- 6. inline interpreter code that writes, deletes, spawns processes, or performs network writes ----
    # Interpreter presence is detected on $stripped (quotes blanked); the write-API scan runs on $flat (quotes kept).
    $interp = $SEP + '(?:python[0-9.]*|py|pypy[0-9]*|node|nodejs|deno|bun|ruby|irb|perl|php|Rscript|R|julia|lua|luajit|tclsh|groovy|scala|kotlinc|dotnet\s+fsi|dotnet\s+script|elixir|erl|ghc|runghc|swift|osascript|jshell)'
    $inline = $interp + '(?:\s+\S+)*\s+(?:-|-c|-e|-p|-E|-r|-l|-x|-m|--eval|--print|--exec|-Command|-c(?:ommand)?|eval|run|--code|-code|repl|<<|<<<)'
    $stdin  = $interp + '(?:\s+-\S+)*\s*(?:$|[;&|)])'
    if ((Has $stripped $inline) -or (Has $stripped $stdin)) {
        $writeApi = '(?:writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|copyFile|copyFileSync|cpSync|rmSync|rmdirSync|unlinkSync|renameSync|mkdirSync|mkdtempSync|symlinkSync|linkSync|truncateSync|chmodSync|chownSync|utimesSync|fs\.promises\.(?:writeFile|appendFile|rm|rmdir|unlink|rename|mkdir|copyFile|cp|truncate|chmod|chown|symlink|link)|fsp\.(?:writeFile|appendFile|rm|rmdir|unlink|rename|mkdir|copyFile)|Deno\.(?:writeFile|writeTextFile|remove|rename|mkdir|copyFile|symlink|link|truncate|chmod|chown|run|Command)|Bun\.(?:write|spawn|spawnSync)|child_process|worker_threads|execSync|spawnSync|execFileSync' +
            '|\.write_text\(|\.write_bytes\(|\.unlink\(|\.rmdir\(|\.rename\(|\.touch\(|\.mkdir\(|\.chmod\(|\.symlink_to\(|\.hardlink_to\(|os\.(?:remove|unlink|rename|renames|replace|rmdir|removedirs|mkdir|makedirs|chmod|chown|lchown|symlink|link|truncate|system|popen|spawn[a-z]*|exec[a-z]*|kill|killpg|startfile|putenv|unsetenv|utime|chdir|fdopen|open\()|shutil\.(?:rmtree|move|copy[a-z]*|make_archive|unpack_archive|chown)|subprocess|multiprocessing|tempfile\.(?:NamedTemporaryFile|mkstemp|mkdtemp|TemporaryDirectory|TemporaryFile)' +
            "|open\([^)]*['""][rwaxbt+]*[wax+][rwaxbt+]*['""]|open\([^)]*mode\s*=\s*['""][rwaxbt+]*[wax+]|io\.open\(|codecs\.open\(|zipfile\.ZipFile\([^)]*['""][wax]|tarfile\.open\([^)]*['""][wax]|sqlite3\.connect|shelve\.open|pickle\.dump|json\.dump\(|yaml\.dump\(|\.to_csv\(|\.to_excel\(|\.to_parquet\(|\.to_pickle\(|\.savefig\(|np\.save|numpy\.save|torch\.save" +
            "|File\.(?:write|open|delete|rename|unlink|WriteAll[A-Za-z]*|Delete|Move|Copy|Create|AppendAll[A-Za-z]*|new\([^)]*['""][wa])|FileUtils|IO\.(?:write|binwrite|copy_stream|popen|sysopen)|Dir\.(?:mkdir|rmdir|delete|unlink|mktmpdir)|Kernel\.(?:system|spawn|exec)|``[^``]*``|%x\(|system\(|exec\(|spawn\(|passthru|shell_exec|proc_open|popen\(|file_put_contents|fwrite|fputs|unlink\(|rmdir\(|mkdir\(|rename\(|copy\(|tempnam|tmpfile" +
            "|\b(?:unlink|rmdir|truncate|symlink|utime|qx|system)\b|open\s*\([^)]*['""]\s*(?:>|\+)" +
            '|Set-Content|Out-File|New-Item|Move-Item|Copy-Item|Add-Content|Rename-Item|Clear-Content|Remove-Item|Invoke-WebRequest|Invoke-RestMethod|Start-Process|Invoke-Expression|Invoke-Command|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|\[IO\.File\]|\[System\.IO\.File\]|WriteAll(?:Text|Bytes|Lines)|AppendAll(?:Text|Lines)|Directory\.(?:Create|Delete|Move)|Process\.Start|ProcessStartInfo|Runtime\.getRuntime\(\)|ProcessBuilder|Files\.(?:write|delete|move|copy|createFile|createDirector[a-z]*|newBufferedWriter|newOutputStream)|FileWriter|FileOutputStream|PrintWriter' +
            '|std::fs::(?:write|remove_[a-z_]+|rename|create_dir[a-z_]*|copy|hard_link|set_permissions)|File::create|OpenOptions|std::process|Command::new|os\.(?:WriteFile|Remove[A-Za-z]*|Rename|Mkdir[A-Za-z]*|Create|OpenFile|Chmod|Chown|Symlink|Link|Truncate)|ioutil\.WriteFile|exec\.Command|System\.IO' +
            '|http\.(?:post|put|patch|delete|request)|requests\.(?:post|put|patch|delete)|urlretrieve|fetch\([^)]*method|axios\.(?:post|put|patch|delete)|net/http|smtplib|ftplib|paramiko|socket\.' +
            '|\b(?:unlink|rmdir|mkdir|rename|chmod|chown|symlink|truncate|system|fork|kill)\b\s*[("\x27$]|open\s*\(?\s*(?:my\s+)?\$\w+\s*,\s*["\x27]\s*\+?[>|])'
        if (Has $flat $writeApi) {
            Deny 'inline interpreter code that writes files, deletes, spawns processes, or performs network writes'
        }
    }

    exit 0
} catch {
    Deny ('internal guard error, failing closed: ' + $_.Exception.Message)
}
