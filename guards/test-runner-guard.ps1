# test-runner-guard.ps1
# PreToolUse hook for the test-runner subagent's Bash tool.
# Reads the hook JSON on stdin, extracts tool_input.command, and BLOCKS (exit 2) commands
# that would modify source files, test expectations, git state, packages, or system state.
#
#   exit 0 = no opinion (normal permission flow continues)
#   exit 2 = blocked; the reason is shown to the agent so it records the run as not performed
#            instead of retrying a variant.
#
# Invoked by the agent frontmatter as:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file>
#
# ADAPTED FROM fim-readonly-guard.ps1, with one deliberate inversion. FIM's guard exists to
# stop an auditor executing project code, so it denies make, bazel, shell scripts,
# `bundle exec`, `poetry run` and similar. Executing the project's test command IS this
# agent's entire job, so those are ALLOWED here. What is denied is mutation.
#
# SCOPE AND ITS LIMIT -- read this before trusting the guard:
#   This guard inspects the COMMAND STRING the agent issues. It does not, and cannot,
#   inspect what a test suite does once running. A test suite legitimately writes caches
#   (.pytest_cache, __pycache__, node_modules/.cache), coverage reports, build output and
#   temp files, and a malicious or misconfigured suite could write anything its process can
#   reach. The guarantee this guard provides is therefore: THE AGENT ISSUES NO MUTATING
#   COMMAND. It is not: NOTHING ON DISK CHANGES. The distinction is stated in the agent's
#   prompt too, and neither claims more.
#   Because it is a command guard rather than a path allowlist, it does not resolve or
#   allowlist directories; `..` and `~` in a path are not a bypass here, since the deny
#   rules match on command tokens (rm, mv, sed -i, ...) wherever the path points.
#
# CASE. Command names resolve case-insensitively on this machine: under Git Bash on
# Windows, `RM`, `SED`, `NPM` and `POWERSHELL` all resolve to the real binaries (observed by
# execution during review). So every command-NAME alternation below is wrapped in a scoped
# (?i:...). FLAGS stay case-sensitive, because each tool parses its own flags and several
# rules depend on the difference: perl -I (include) vs -i (in place), git -C vs -c, pacman
# -S/-R/-U vs -Q, interpreter -e vs -E, and the sed and tar flag clusters. Do NOT put
# IgnoreCase on Has(): it would silently change every one of those. Where a name
# alternation already contains a fixed subcommand word (cargo fmt, uv pip, docker compose,
# flask run), that word is inside the scope too; that can only add denials for uppercase
# spellings, never remove one. The PowerShell rule is the one exception to "flags stay
# case-sensitive", because PowerShell itself parses parameters case-insensitively and by
# prefix.
#
# KNOWN AND ACCEPTED GAPS. Each was reviewed, and each is left open deliberately because
# closing it would deny something the agent must be able to do, or would rest the guard's
# correctness on something fragile. This list records every gap found so far. It is NOT a
# claim of completeness: a round-3 review found a fail-open that no entry covered, and
# there may be others. If you find one, add it here.
#   1. Quoted payloads. Token rules run against $stripped, in which quoted regions are
#      blanked, so `rm` inside quotes is invisible to them. What catches quoted mutation is
#      the enumeration of shells, subshells, and interpreters below, not the token rules.
#      A wrapper outside that enumeration that executes a quoted string is a bypass.
#   2. Path-prefixed binaries. $SEP deliberately excludes `/` so that `./gradlew test` and
#      `vendor/bin/phpunit` run. Rule 2 covers the highest-value mutators in path-prefixed
#      form (/bin/rm, \rm and similar), but only in command-initial position (see gap 4);
#      the general case remains open.
#   3. Reporter-output flags. `--junitxml=report.xml`, `--outputFile=results.json` and their
#      equivalents write a file and are NOT denied. This is deliberate: a project whose own
#      configured test command emits a JUnit report is doing something legitimate, and
#      denying it would make that project untestable. The prompt forbids the agent from
#      ADDING such a flag on its own authority; the guard does not enforce that one.
#   4. Mutators and subshells in ARGUMENT position. Rule 2 and the cmd/wsl alternative are
#      anchored at command-initial position, so `/bin/rm x`, `foo && /bin/rm x`,
#      `cmd /c ...` and `foo | cmd /c ...` deny, but `xargs /bin/rm`, `time cmd /c ...` and
#      `env cmd /c ...` do not. The anchors are what let a test path whose last segment is
#      named `install` or `rm` (`pytest ./tests/install`) and a directory named `cmd`
#      (`cd cmd && go test ./...`) run at all. Argument-position execution by a dispatcher
#      is accepted as out of reach for a command-string guard.
#   5. Value-taking wrapper options. The npx/env shell-string rule skips flag-shaped tokens
#      (--yes), assignment-shaped tokens (FOO=bar), and the named pair -p/--package with
#      its one value. Any OTHER option written with its value as a separate token breaks
#      the chain before the shell-string flag is reached, and the command is allowed:
#      `env -u VAR -S '...'` and `env -C dir -S '...'` are known examples. A general "skip
#      a flag and its value" rule is not used, because whether a flag takes a value cannot
#      be read from the string, and the general form would swallow the wrapped command's
#      name, so that `npx --yes jest -c cfg` would deny.
#   6. `perl -i<ext>` with no dot. The perl rule requires the in-place `i` to end its flag
#      cluster or be followed by `.ext`, so that `perl -Ilib` runs. `perl -ibak -pe ...`
#      therefore edits in place and is allowed. Widening the pattern to catch it would
#      leave `perl -Ilib` safe only because `I` is uppercase, which is too fragile a thing
#      for the guard's correctness to rest on.
#   7. Windows-native subcommands and switches. The (?i) scopes cover command NAMES only
#      (see CASE). Windows-native tools such as net and sc are expected to accept their
#      own subcommands in any case (not verified), so `net STOP svc` and `sc CONFIG svc`
#      are not matched even though `net stop svc` and `sc config svc` are denied.
#   Each of these requires the agent to construct an unusual command. The prompt forbids
#   exactly that, in section 1.2. Guard and prompt are two layers, and neither is complete
#   alone.
#
# NOTE ON --in-place. The general fix/write-flag rule denies `--in-place` anywhere in the
# command and is the real gate for it. The `--in-place` alternatives inside the sed and perl
# rules only change which reason string is printed. Editing the general rule therefore
# changes sed and perl behavior too.
#
# Deliberately conservative elsewhere: a rare false positive costs one denied call and a
# line in the agent's NOT RUN section; a false negative would break the never-edits-code
# promise. Any internal error fails CLOSED (denies).
#
# DELIBERATE ALLOWANCES, each a considered trade:
#   - Test scripts and binaries (./gradlew, ./scripts/test.sh, vendor/bin/phpunit) execute.
#     The agent is instructed to run only the caller-supplied or config-derived test command.
#   - Runner wrappers (bundle exec, poetry run, uv run, pipenv run, npx, pnpm dlx) execute,
#     including with their own config flags (npx jest -c jest.config.js). Only a shell-string
#     flag in the WRAPPER'S OWN option position (npx -c "...", env -S "...") is denied.
#   - make / mvn / gradle / bazel / cmake targets execute; `install` targets are denied.
#   - Build steps execute, because some suites cannot run without one.

$ErrorActionPreference = 'Stop'

function Deny([string]$reason) {
    # Escape for JSON rather than stripping, so the reason reaches the agent intact.
    $safe = $reason -replace '[\r\n\t]+', ' '
    $esc  = $safe -replace '\\', '\\' -replace '"', '\"'
    $json = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"test-runner guard: ' + $esc + '"}}'
    [Console]::Out.WriteLine($json)
    [Console]::Error.WriteLine('TEST-RUNNER GUARD BLOCKED THIS COMMAND.')
    [Console]::Error.WriteLine('Reason: ' + $safe)
    [Console]::Error.WriteLine('You run tests and report. You never edit code, never update a snapshot, never install, never fix. Do NOT retry a variant that performs the same mutation and do NOT route around this block. Record the affected check under NOT RUN with the exact command the caller could run themselves, then continue with the rest of the report.')
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
    Deny 'could not read tool_input.command from the hook input, so the command cannot be proven non-mutating (fail closed)'
}

try {
    # ---- normalize -------------------------------------------------------------------
    # flat     : whole command on one line (heredoc bodies included)
    # stripped : quoted strings blanked, so grep patterns / test names do not trigger rules
    # noredir  : harmless redirections (to /dev/null, fd-to-fd) removed before the redirect check
    $flat     = $cmd -replace '[\r\n]+', ' '
    $stripped = [regex]::Replace($flat, "'[^']*'", "''")
    $stripped = [regex]::Replace($stripped, '"(?:[^"\\]|\\.)*"', '""')
    $noredir  = $stripped -replace '\d*>{1,2}\s*/dev/null', ''
    $noredir  = $noredir  -replace '&>{1,2}\s*/dev/null', ''
    $noredir  = $noredir  -replace '\d*>&\d+', ''
    $noredir  = $noredir  -replace '\d*>&-', ''

    $SEP  = '(?:^|[\s;&|(])'      # token boundary: start, whitespace, or shell separator
                                  # (NOT "-", so --rm does not match rm; NOT "/", so
                                  # ./gradlew runs -- see KNOWN AND ACCEPTED GAPS 2)
    $END  = '(?:\s|$)'
    $ARG  = '[^\s;&|()]'          # one argument character, never a shell separator, so that
                                  # argument-skipping quantifiers cannot walk into the next
                                  # command and pair a verb with a stranger's flag
    $FLAG = '\s+(?:-' + $ARG + '*|' + $ARG + '+=' + $ARG + '*)'
                                  # ONE skippable token: flag-shaped (--yes) or
                                  # assignment-shaped (FOO=bar). Never a bare word, so a rule
                                  # looking for a wrapper's own option cannot match the same
                                  # option belonging to the wrapped command (npx jest -c cfg).
                                  # Used only by the npx/env rule, which repeats it.
    $CMD  = '(?:^|[;&|(])\s*'     # command-INITIAL position only
    $ISEP = '(?:^|[\s;&|(''"])'   # like $SEP, but also matches after a quote, so that a
                                  # quoted interpreter name still arms the write-API scan

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
        Deny 'output redirection (> or >>) writes a file; capture the runner output in the tool result instead, or redirect only to /dev/null or between file descriptors'
    }

    # ---- 2. simple deny rules --------------------------------------------------------
    # Every command-NAME alternation is inside (?i:...); flags are outside it. See CASE.
    $rules = @(
        @('file or permission mutation command (rm mv cp mkdir touch tee chmod install sudo ...)',
          ($SEP + '(?i:rm|rmdir|unlink|shred|mv|cp|dd|tee|truncate|chmod|chown|chgrp|chattr|ln|mkdir|touch|install|mkfs|mount|umount|del|erase|rd|md|move|copy|ren|rename|xcopy|robocopy|attrib|icacls|takeown|sudo|doas|runas|su|sponge)' + $END)),
        @('path-prefixed file mutation command (/bin/rm, /usr/bin/sed, \rm ...)',
          ($CMD + '(?:\\(?i:rm|mv|cp|dd|sed|chmod|tee)|(?:[A-Za-z]:)?[./\\]' + $ARG + '*[/\\](?i:rm|mv|cp|dd|sed|chmod|chown|ln|truncate|shred|unlink|tee|install))' + $END)),
        @('find -delete / -fprint / -fls writes or deletes files',
          '(?:^|\s)(?:-delete|-fprint0?|-fls|-fprintf)(?:\s|$)'),
        @('sed -i edits files in place',
          ($SEP + '(?i:sed)(?:\s+' + $ARG + '+)*\s+(?:-[a-zA-Z]*i[a-zA-Z]*|--in-place)')),
        @('perl -i edits files in place (perl -Ilib and other include flags are allowed)',
          ($SEP + '(?i:perl)(?:\s+-[a-zA-Z0-9]*)*\s+-[a-zA-Z0-9]*i(?:\.' + $ARG + '*)?' + $END + '|' + $SEP + '(?i:perl)(?:\s+' + $ARG + '+)*\s+--in-place')),
        @('awk -i inplace edits files in place',
          ($SEP + '(?i:g?awk)(?:\s+' + $ARG + '+)*\s+-i\s+inplace')),
        @('text editors can modify files',
          ($SEP + '(?i:ed|ex|vi|vim|nvim|nano|pico|emacs|micro|joe|notepad|notepad\+\+|code|subl|gedit)' + $END)),
        @('package install, update, publish, or cache command; the agent runs the suite as the project already stands and never installs dependencies',
          ($SEP + '(?i:npm|pnpm|yarn|bun)\s+(?:i|install|add|remove|rm|r|un|uninstall|unlink|link|update|up|upgrade|publish|ci|init|create|prune|dedupe|ddp|rebuild|rb|set|set-script|pkg|version|deprecate|dist-tag|owner|access|login|logout|adduser|token|hook|star|unstar|cache|import|patch|patch-commit|store|setup|self-update)' + $END)),
        @('bare yarn/bun installs dependencies',
          ($SEP + '(?i:yarn|bun)\s*(?:$|[;&|)])')),
        @('pip/pipx install or write command',
          ($SEP + '(?i:pip|pip3|pipx|uv\s+pip)\s+(?:install|uninstall|download|wheel|cache|config|inject|reinstall|ensurepath|upgrade|upgrade-all)' + $END)),
        @('uv write command (uv run is allowed)',
          ($SEP + '(?i:uv)\s+(?:add|remove|sync|lock|venv|init|build|publish|tool|python|self|cache)' + $END)),
        @('poetry write command (poetry run is allowed)',
          ($SEP + '(?i:poetry)\s+(?:add|remove|update|lock|build|publish|env|self|cache|init|new|source|install|shell)' + $END)),
        @('conda/mamba environment write command',
          ($SEP + '(?i:conda|mamba|micromamba)\s+(?:install|remove|uninstall|update|create|env|clean|init|config|rename)' + $END)),
        @('pipenv write command (pipenv run is allowed)',
          ($SEP + '(?i:pipenv)\s+(?:install|uninstall|update|lock|sync|clean|--rm|shell)' + $END)),
        @('python environment or packaging write command',
          ($SEP + '(?:(?i:virtualenv)' + $END + '|(?i:python)[0-9.]*\s+-m\s+(?:venv|pip|ensurepip|compileall|build|twine)' + $END + ')')),
        @('cargo write or publish command (cargo test / nextest / check / build are allowed)',
          ($SEP + '(?i:cargo)\s+(?:install|uninstall|add|remove|rm|publish|update|new|init|clean|generate-lockfile|vendor|yank|owner|login|logout|fix|package)' + $END)),
        @('rustup modifies the toolchain',
          ($SEP + '(?i:rustup)\s+(?:install|uninstall|update|default|toolchain|target|component|self|override|set)' + $END)),
        @('go write command (go test / build / vet / list are allowed)',
          ($SEP + '(?i:go)\s+(?:get|clean|fix|generate|install|telemetry|env\s+-w|mod\s+(?:tidy|download|vendor|edit|init)|work\s+(?:init|use|sync|edit))' + $END)),
        @('ruby/php package manager write command (bundle exec and composer run-script are allowed)',
          ($SEP + '(?:(?i:gem)\s+(?:install|uninstall|update|push|cleanup|yank|owner)|(?i:bundle)\s+(?:install|update|add|remove|clean|pristine|lock|init|config)|(?i:composer)\s+(?:install|update|require|remove|create-project|dump-autoload|dumpautoload|clear-cache|clearcache|self-update|selfupdate|init|config))' + $END)),
        @('system package manager write command',
          ($SEP + '(?i:apt|apt-get|aptitude|dnf|yum|pacman|zypper|apk|brew|choco|winget|scoop|snap|flatpak|nix-env|port|emerge)\s+(?:install|remove|uninstall|purge|upgrade|update|autoremove|autoclean|clean|dist-upgrade|full-upgrade|add|del|tap|untap|link|unlink|pin|unpin|cleanup|refresh|reinstall|reset|hold|unhold|-S[a-zA-Z]*|-R[a-zA-Z]*|-U[a-zA-Z]*|--sync|--remove|--upgrade)' + $END)),
        @('dotnet/nuget write or publish command (dotnet test and dotnet build are allowed)',
          ($SEP + '(?:(?i:dotnet)\s+(?:add|remove|restore|publish|pack|nuget|tool|new|clean|workload|user-secrets|dev-certs|ef|watch)|(?i:nuget)\s+(?:push|delete|update|restore|sources|install))' + $END)),
        @('toolchain manager modifies the environment',
          ($SEP + '(?i:nvm|pyenv|rbenv|asdf|volta|fnm|sdk|corepack|direnv|mise|proto)\s+(?:install|uninstall|use|global|local|alias|unalias|default|pin|plugin|reshim|shell|enable|disable|prepare|allow|deny|set|activate|trust|self-update|upgrade|update)' + $END)),
        @('fix or write flag would modify files; the agent reports failures and never repairs them',
          '(?:^|\s)(?:--fix|--fix-only|--fix-type|--write|--apply|--apply-unsafe|--unsafe-fixes|--autocorrect(?:-all)?|--in-place|--save|--save-dev|--save-exact)(?:[\s=]|$)'),
        @('snapshot or golden-file update flag rewrites the recorded test expectations, which is editing the test',
          '(?:^|\s)(?:--update-snapshot|--update-snapshots|--updateSnapshot|--updateSnapshots|--snapshot-update|--force-update-snapshots|--update-golden|--update-goldens|--force-regen|--regen-all|--accept|--bless|-update|--update)(?:[\s=]|$)'),
        @('-u on a JS test runner updates snapshots (mocha is excluded: its -u selects the interface)',
          ($SEP + '(?i:jest|vitest|ava|jasmine|cypress|playwright)(?:\s+' + $ARG + '+)*\s+-u' + $END)),
        @('insta/approval-test review command rewrites recorded expectations',
          ($SEP + '(?i:cargo\s+insta|insta)\s+(?:accept|review|test\s+--accept)' + $END)),
        @('formatter writes files by default; formatting is not this agent job',
          ($SEP + '(?i:gofmt|goimports|shfmt|prettier|black|isort|rustfmt|cargo\s+fmt|ruff\s+format|clang-format|autopep8|yapf|rubocop|deno\s+fmt|dart\s+format|mix\s+format|dotnet\s+format|swiftformat|stylua|taplo\s+fmt|zig\s+fmt|elm-format|scalafmt|ktlint|google-java-format)' + $END)),
        @('container command that builds, runs, or modifies containers or images; a containerized suite is out of scope for this agent',
          ($SEP + '(?i:docker(?:\s+compose)?|docker-compose|podman|nerdctl)\s+(?:build|run|up|down|push|pull|rm|rmi|exec|create|start|stop|restart|kill|commit|cp|import|load|save|login|logout|attach|pause|unpause|rename|update|export|buildx|swarm|service|stack|node|secret|system|volume|network|image|container|context)' + $END)),
        @('cloud, cluster, deployment, or remote-shell CLI; this agent never touches infrastructure or remote hosts',
          ($SEP + '(?i:kubectl|oc|helm|terraform|tofu|pulumi|cdk|cdktf|sam|serverless|sls|aws|gcloud|gsutil|az|flyctl|fly|vercel|netlify|heroku|wrangler|firebase|supabase|railway|doctl|oci|ibmcloud|ansible|ansible-playbook|vagrant|packer|nomad|consul|vault|k3d|kind|minikube|eksctl|argocd|flux|istioctl|linkerd|skaffold|tilt|okteto|render|dokku|kamal|capistrano|cap|fab|fabric|ssh|scp|sftp|rsync|ftp|telnet|nc|ncat|netcat|socat|mosh)' + $END)),
        @('download command',
          ($SEP + '(?i:wget|aria2c|axel|Invoke-WebRequest|iwr|Invoke-RestMethod|irm|Start-BitsTransfer|bitsadmin)' + $END)),
        @('certutil download or store modification',
          ($SEP + '(?i:certutil)(?:\s+' + $ARG + '+)*\s+-(?:urlcache|decode|encode|addstore|delstore)')),
        @('HTTP write request',
          ($SEP + '(?i:http|https|xh)\s+(?:-' + $ARG + '+\s+)*(?:POST|PUT|PATCH|DELETE)' + $END)),
        @('process, service, scheduling, registry, disk, user, or firewall command',
          ($SEP + '(?i:kill|killall|pkill|taskkill|shutdown|reboot|halt|poweroff|telinit|systemctl|launchctl|setx|schtasks|crontab|bcdedit|diskpart|fdisk|parted|gdisk|sfdisk|wipefs|swapon|swapoff|sysctl|ufw|iptables|ip6tables|nft|firewall-cmd|netsh|hostnamectl|timedatectl|useradd|userdel|usermod|groupadd|groupdel|passwd|chpasswd|visudo|update-alternatives|ldconfig|modprobe|insmod|rmmod|dism|sfc|powercfg|wmic|gpupdate|gpedit|regedit|reg|Start-Service|Stop-Service|Restart-Service|Set-Service|New-Service|Stop-Process|Start-Process|Stop-Computer|Restart-Computer)' + $END)),
        @('service, network, or user modification command',
          ($SEP + '(?:(?i:sc)\s+(?:create|delete|config|start|stop|pause|continue|failure|sdset)|(?i:net)\s+(?:start|stop|user|localgroup|share|use|config|accounts|file|time)|(?i:service)\s+' + $ARG + '+\s+(?:start|stop|restart|reload|enable|disable)|(?i:route)\s+(?:add|del|delete|change|flush|-p)|(?i:ifconfig)\s+' + $ARG + '+\s+(?:up|down|add|del|inet|netmask|mtu|hw)|(?i:ip)\s+(?:link|addr|address|route|rule|neigh|netns)\s+(?:add|del|delete|set|flush|change|replace))' + $END)),
        @('inline shell code hides the real command from the guard; invoke the test command directly',
          ($SEP + '(?i:bash|sh|zsh|dash|ksh|fish|busybox)(?:\s+-[a-zA-Z]*)*\s+-[a-zA-Z]*c' + $END)),
        # The powershell/pwsh/osascript/expect alternative is CASE-INSENSITIVE and matches the
        # inline-code switch BY PREFIX, because PowerShell accepts parameter names in any case
        # and as any unambiguous prefix: -c, -com, -command, -Command; -e, -ec, -en, -enc,
        # -EncodedCommand. The -e branch is deliberately NOT -e[a-z]*, which would also match
        # -ExecutionPolicy and deny the allowed form: powershell -ExecutionPolicy Bypass -File x.ps1
        @('inline powershell/cmd/wsl code cannot be inspected by the guard; invoke the test command directly (powershell -File is allowed)',
          ($SEP + '(?i:(?:powershell|pwsh|powershell\.exe|pwsh\.exe|osascript|expect)(?:\s+' + $ARG + '+)*\s+-(?:c[a-z]*|e(?:c|n[a-z]*)?))' + $END + '|' + $CMD + '(?i:cmd|cmd\.exe|wsl|wsl\.exe)' + $END)),
        @('a runner invoked with a shell-string flag in its own option position (npx -c, env -S, dlx -c) executes code the guard cannot inspect',
          ($SEP + '(?i:npx|env|(?:pnpm|yarn|bun)\s+(?:dlx|x))(?:\s+(?:-p|--package)\s+' + $ARG + '+|' + $FLAG + ')*\s+(?:-c|-S|--call|--command)' + $END)),
        @('eval, exec, or source as the leading command runs code the guard cannot inspect (bundle exec, npm exec and similar subcommand forms are allowed)',
          ($CMD + '(?i:eval|exec|source)\s|' + $CMD + '\.\s')),
        @('background or long-running process control; the suite must run to completion in the foreground',
          ($SEP + '(?i:nohup|setsid|disown|inotifywait|fswatch|entr|nodemon|ts-node-dev|supervisord|pm2|forever|cargo\s+watch|watchexec)' + $END)),
        @('watch, sleep, or terminal multiplexer as the leading command',
          ($CMD + '(?i:watch|sleep|screen|tmux)' + $END)),
        @('trailing & starts a background process',
          '(?:^|[^&])&\s*(?:$|[;)])'),
        @('watch or serve mode never terminates',
          '(?:^|\s)(?:--watch(?:All)?|--watch-path|--watchAll|--hot|--live-reload|--serve|--interactive)(?:[\s=]|$)'),
        @('watch or browser-UI mode never terminates',
          ($SEP + '(?i:tsc|jest|vitest|mocha|karma|webpack|rollup|esbuild|parcel|swc|babel|sass|less|postcss|tailwindcss|ng|pytest-watch|ptw)(?:\s+' + $ARG + '+)*\s+(?:-w|--watch)' + $END + '|' + $SEP + '(?i:vitest|playwright)(?:\s+' + $ARG + '+)*\s+--ui' + $END + '|' + $SEP + '(?i:cypress)\s+open' + $END)),
        @('starting a server or dev process never terminates',
          ($SEP + '(?:(?i:serve|http-server|live-server|json-server|webpack-dev-server|uvicorn|gunicorn|hypercorn|daphne|waitress-serve|flask\s+run|django-admin\s+runserver|manage\.py\s+runserver|rails\s+s(?:erver)?|php\s+artisan\s+serve|vite(?:\s+(?:dev|serve|preview))?|next\s+(?:dev|start)|nuxt(?:\s+(?:dev|start|preview))?|astro\s+(?:dev|preview)|remix\s+dev|ng\s+serve|expo\s+start|react-native\s+start|storybook\s+dev|hugo\s+server|jekyll\s+serve|mkdocs\s+serve|spring-boot:run|air|reflex)|(?i:php)\s+-S)' + $END)),
        @('archive extraction or compression creates files',
          ($SEP + '(?i:unzip|zip|gzip|gunzip|bzip2|bunzip2|xz|unxz|zstd|unzstd|7z|7za|7zr|unrar|rar|cpio|cabextract|Expand-Archive|Compress-Archive)' + $END)),
        @('tar extraction writes files (tar -t to list is allowed)',
          ($SEP + '(?i:tar)(?:\s+-?[a-zA-Z]*x[a-zA-Z]*|(?:\s+' + $ARG + '+)*\s+--extract)' + $END)),
        @('piping into a shell, interpreter, clipboard, or mailer executes or exfiltrates content',
          '\|\s*(?i:bash|sh|zsh|dash|ksh|fish|python[0-9.]*|node|ruby|perl|php|pwsh|powershell|cmd|clip|xclip|xsel|pbcopy|lp|lpr|wall|write|mail|sendmail|msmtp)(?:\s|$)')
    )
    foreach ($r in $rules) {
        if (Has $noredir $r[1]) { Deny $r[0] }
    }

    # ---- 3. package scripts that mutate; test/build/check scripts are allowed ----------
    if (Has $noredir ($SEP + '(?i:npm|pnpm|yarn|bun)\s+(?:run(?:-script)?\s+)?(?:' + $ARG + '*[:/])?(?:dev|start|serve|preview|watch|deploy|publish|release|clean|format|fmt|fix|lint-fix|lintfix|migrate|seed|generate|gen|codegen|prepare|prepublish|postinstall|preinstall|install|write|snapshot|snapshots|update-snapshots|approve|bless)' + $END)) {
        Deny 'package script that starts a server, watches, deploys, migrates, formats, fixes, or rewrites snapshots'
    }

    # ---- 4. git: allowlist of read-only subcommands; anything else is denied -----------
    if (Has $noredir ($SEP + '(?i:git)' + $END)) {
        $gitPre   = '(?i:git)(?:\s+(?:-C\s+' + $ARG + '+|-c\s+' + $ARG + '+|--[a-z-]+(?:=' + $ARG + '*)?|-[a-zA-Z]+))*'
        $readOnly = '^' + $gitPre + '\s+(?:status|log|diff|show|blame|grep|ls-files|ls-tree|ls-remote|rev-parse|rev-list|describe|cat-file|shortlog|whatchanged|name-rev|merge-base|count-objects|var|version|--version|help|check-ignore|check-attr|check-mailmap|for-each-ref|show-ref|diff-tree|diff-index|diff-files|verify-commit|verify-tag|show-branch|cherry|range-diff)(?:\s+' + $ARG + '+)*$'
        $listing  = '^' + $gitPre + '\s+(?:' +
            'stash\s+(?:list|show)(?:\s+' + $ARG + '+)*' +
            '|tag(?:\s+(?:-l\s+' + $ARG + '+|-l|--list\s+' + $ARG + '+|--list|-n\d*|--contains(?:\s+' + $ARG + '+)?|--points-at\s+' + $ARG + '+|--sort=' + $ARG + '+|--format=' + $ARG + '*|--merged(?:\s+' + $ARG + '+)?|''''|""))*' +
            '|branch(?:\s+(?:-a|-r|-v|-vv|-l\s+' + $ARG + '+|-l|--list\s+' + $ARG + '+|--list|--all|--remotes|--show-current|--contains(?:\s+' + $ARG + '+)?|--merged(?:\s+' + $ARG + '+)?|--points-at\s+' + $ARG + '+|--sort=' + $ARG + '+|--format=' + $ARG + '*|''''|""))*' +
            '|remote(?:\s+(?:-v|--verbose|show(?:\s+' + $ARG + '+)*|get-url(?:\s+' + $ARG + '+)*))*' +
            '|config\s+(?:--global\s+|--local\s+|--system\s+|--worktree\s+)?(?:--get|--get-all|--get-regexp|--list|-l|--show-origin|--show-scope)(?:\s+' + $ARG + '+)*' +
            '|reflog(?:\s+show(?:\s+' + $ARG + '+)*)?' +
            '|worktree\s+list(?:\s+' + $ARG + '+)*' +
            '|submodule\s+status(?:\s+' + $ARG + '+)*' +
            '|lfs\s+(?:ls-files|status|env|version)(?:\s+' + $ARG + '+)*' +
            ')$'
        $ms = [regex]::Matches($noredir, $SEP + '(' + $gitPre + '\s+' + $ARG + '+(?:\s+' + $ARG + '+)*)')
        foreach ($m in $ms) {
            $inv = $m.Groups[1].Value
            if (Has $inv '(?:^|\s)--output(?:[\s=]|$)') { Deny 'git --output writes a file' }
            if (Has $inv $readOnly) { continue }
            if (Has $inv $listing)  { continue }
            Deny 'git command is not in the read-only allowlist (allowed: status log diff show blame grep ls-files rev-parse describe cat-file, stash list/show, tag/branch/remote listing, config --get/--list)'
        }
    }

    # ---- 5. make: allowed, except targets whose names announce mutation -----------------
    if (Has $noredir ($SEP + '(?i:make|gmake)\s+(?:' + $ARG + '+\s+)*(?:install|uninstall|clean-all|distclean|deploy|publish|release|format|fmt|fix|migrate|seed|generate|codegen|bootstrap|setup|update-snapshots)' + $END)) {
        Deny 'make target announces a mutating action; only test, check, build and similar read-or-run targets are allowed'
    }

    # ---- 6. curl with a writing, uploading, or downloading option ----------------------
    if ((Has $noredir ($SEP + '(?i:curl)' + $END)) -and (Has $noredir '(?:^|\s)(?:-X\s*(?:POST|PUT|PATCH|DELETE)|--request[\s=]*(?:POST|PUT|PATCH|DELETE)|-d|--data(?:-[a-z]+)?|-F|--form|-T|--upload-file|-o|-O|--output|--remote-name|-J|--remote-header-name|-K|--config|--create-dirs|-c|--cookie-jar|--trace(?:-[a-z]+)?|--dump-header|-D)(?:[\s=]|$)')) {
        Deny 'curl with a writing, uploading, or downloading option'
    }

    # ---- 7. inline interpreter code that writes, deletes, spawns, or performs net writes ----
    # Two-stage, and the stages read different strings on purpose:
    #   DETECTION arms on an interpreter invoked with a flag that takes CODE (-c, -e, --eval,
    #   heredoc). It runs against BOTH $stripped and $flat, so that quoting the interpreter
    #   name -- "python" -c ... -- does not hide it. $ISEP and the trailing quote class let
    #   the pattern match a quoted name. The interpreter NAME is case-insensitive (see CASE);
    #   the code flags in $inline are not.
    #   The WRITE-API SCAN runs against $flat, because the code being examined lives inside
    #   quotes and $stripped has blanked it.
    # Module names use a non-word LEFT boundary rather than a trailing call delimiter, so
    # that an aliased import (`import subprocess as sp; sp.run(...)`) is still caught while
    # a path or identifier that merely contains the name (tests/test_subprocess.py) is not.
    # The lookbehind excludes `.` `/` `\` and `-` as well as word characters, so a path
    # segment such as tests/subprocess_helper.py cannot match either.
    $interp = $ISEP + '(?i:python[0-9.]*|py|pypy[0-9]*|node|nodejs|deno|bun|ruby|irb|perl|php|Rscript|R|julia|lua|luajit|tclsh|groovy|scala|kotlinc|dotnet\s+fsi|dotnet\s+script|elixir|erl|ghc|runghc|swift|jshell)[''"]?'
    $inline = $interp + '(?:\s+' + $ARG + '+)*\s+(?:(?:-c|-e|-E|-p|-r|--eval|--print|--exec|--code|-code|eval|repl)(?:\s|=|$)|<<)'
    $stdin  = $interp + '(?:\s+-' + $ARG + '+)*\s*(?:$|[;&|)])'
    if ((Has $stripped $inline) -or (Has $stripped $stdin) -or (Has $flat $inline) -or (Has $flat $stdin)) {
        $writeApi =
            '(?<![\w./\\-])(?:subprocess|multiprocessing|child_process|worker_threads|smtplib|ftplib|paramiko|shutil|FileUtils|pathlib)\b' +
            '|(?:writeFile|writeFileSync|appendFile|appendFileSync|createWriteStream|copyFile|copyFileSync|cpSync|rmSync|rmdirSync|unlinkSync|renameSync|mkdirSync|mkdtempSync|symlinkSync|linkSync|truncateSync|chmodSync|chownSync|utimesSync|execSync|spawnSync|execFileSync|writeTextFile)\s*\(' +
            '|require\s*\(\s*[''"](?:fs|fs/promises|node:fs)|(?:import|from)\s+[''"](?:fs|node:fs|fs/promises)' +
            '|fs\.promises\.(?:writeFile|appendFile|rm|rmdir|unlink|rename|mkdir|copyFile|cp|truncate|chmod|chown|symlink|link)' +
            '|Deno\.(?:writeFile|writeTextFile|remove|rename|mkdir|copyFile|symlink|link|truncate|chmod|chown|run|Command)' +
            '|Bun\.(?:write|spawn|spawnSync)' +
            '|\.write_text\s*\(|\.write_bytes\s*\(|\.unlink\s*\(|\.rmdir\s*\(|\.rename\s*\(|\.touch\s*\(|\.mkdir\s*\(|\.chmod\s*\(|\.symlink_to\s*\(' +
            '|os\.(?:remove|unlink|rename|renames|replace|rmdir|removedirs|mkdir|makedirs|chmod|chown|lchown|symlink|link|truncate|system|popen|spawn[a-z]*|exec[a-z]*|kill|killpg|startfile|putenv|unsetenv|utime)\s*\(' +
            "|open\([^)]*['""][rwaxbt+]*[wax+][rwaxbt+]*['""]|open\([^)]*mode\s*=\s*['""][rwaxbt+]*[wax+]|io\.open\s*\(|codecs\.open\s*\(" +
            "|zipfile\.ZipFile\([^)]*['""][wax]|tarfile\.open\([^)]*['""][wax]|shelve\.open\s*\(|pickle\.dump\s*\(|json\.dump\s*\(|yaml\.dump\s*\(|\.to_csv\s*\(|\.to_excel\s*\(|\.to_parquet\s*\(|\.to_pickle\s*\(|\.savefig\s*\(|np\.save\s*\(|numpy\.save\s*\(|torch\.save\s*\(" +
            '|urlretrieve\s*\(|requests\.(?:post|put|patch|delete)\s*\(|http\.(?:post|put|patch|delete|request)\s*\(|axios\.(?:post|put|patch|delete)\s*\(|fetch\([^)]*method' +
            "|File\.(?:write|delete|rename|unlink|open|WriteAll[A-Za-z]*|Delete|Move|Copy|Create|AppendAll[A-Za-z]*)\s*\(" +
            "|IO\.(?:write|binwrite|copy_stream|popen|sysopen)\s*\(|Dir\.(?:mkdir|rmdir|delete|unlink|mktmpdir)\s*\(|Kernel\.(?:system|spawn|exec)\s*\(|%x\(|``[^``]*``" +
            "|file_put_contents\s*\(|fwrite\s*\(|fputs\s*\(|shell_exec\s*\(|proc_open\s*\(|passthru\s*\(|tempnam\s*\(|tmpfile\s*\(" +
            '|Set-Content|Out-File|New-Item|Move-Item|Copy-Item|Add-Content|Rename-Item|Clear-Content|Remove-Item|Invoke-WebRequest|Invoke-RestMethod|Start-Process|Invoke-Expression|Set-ItemProperty|New-ItemProperty|Remove-ItemProperty|\[IO\.File\]|\[System\.IO\.File\]' +
            '|WriteAll(?:Text|Bytes|Lines)\s*\(|AppendAll(?:Text|Lines)\s*\(|Directory\.(?:Create|Delete|Move)|Process\.Start\s*\(|ProcessBuilder\s*\(|Files\.(?:write|delete|move|copy|createFile|createDirector[a-z]*|newBufferedWriter|newOutputStream)\s*\(|FileWriter\s*\(|FileOutputStream\s*\(|PrintWriter\s*\(' +
            '|std::fs::(?:write|remove_[a-z_]+|rename|create_dir[a-z_]*|copy|hard_link|set_permissions)|File::create|OpenOptions::|std::process::|Command::new' +
            '|os\.(?:WriteFile|Remove[A-Za-z]*|Rename|Mkdir[A-Za-z]*|Create|OpenFile|Chmod|Chown|Symlink|Link|Truncate)\s*\(|ioutil\.WriteFile\s*\(|exec\.Command\s*\(' +
            '|\b(?:unlink|rmdir|mkdir|rename|chmod|chown|symlink|truncate|fork|kill)\b\s*[("\x27$]|open\s*\(?\s*(?:my\s+)?\$\w+\s*,\s*["\x27]\s*\+?[>|]'
        if (Has $flat $writeApi) {
            Deny 'inline interpreter code that writes files, deletes, spawns processes, or performs network writes'
        }
    }

    exit 0
} catch {
    Deny ('internal guard error, failing closed: ' + $_.Exception.Message)
}
