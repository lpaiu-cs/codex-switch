<div align="center">

# codex-switch

**Use more than one ChatGPT account with Codex on Windows.**

Switch in a second, stay logged in, keep your threads and settings.

[**English**](#quick-start) · [**한국어**](#한국어) · [Download](https://github.com/lpaiu-cs/codex-switch/releases/latest) · [Changelog](CHANGELOG.md) · [Design notes](docs/DESIGN.md)

</div>

```
=== codex-switch ===
Active: main  me@gmail.com  (plus)

  1) main          me@gmail.com  (plus)  [active]
  2) work          me@company.com  (team)
  N) Add new profile (log in with another account)
  Q) Quit

Select:
```

Pick a number, press Enter. Codex reopens on that account.

> [!NOTE]
> Unofficial community tool. Not affiliated with or endorsed by OpenAI. It moves Codex's local
> `auth.json`, an undocumented file whose layout can change between releases. Intended for switching
> between accounts you own (personal / work); OpenAI's terms prohibit using multiple accounts to get
> around usage limits. Use at your own risk.

Sibling project: [claude-switch](https://github.com/lpaiu-cs/claude-switch) does the same for Claude
Desktop. The two look alike on the outside and are built differently on the inside, because the two
apps store an account very differently. See [docs/DESIGN.md](docs/DESIGN.md) for the comparison.

---

## Quick start

**You need:** Windows 10/11 · Codex logged in at least once, via the **Codex desktop app** (Microsoft
Store) or the **`codex` CLI** in a terminal. Either works; both share the same login.

Windows PowerShell 5.1 is already on your machine — nothing to install.

### Option A — download (no developer tools)

1. Get `codex-switch-<version>.zip` from the [latest release](https://github.com/lpaiu-cs/codex-switch/releases/latest).
2. Right-click the zip → **Extract All**. Running it from inside the zip does not work.
3. Double-click **`시작하기.cmd`**.

If Windows says *"Windows protected your PC"*, click **More info → Run anyway**. That prompt shows
up for any script downloaded from the internet.

The zip also contains **`사용설명서.md`**, a plain-language Korean walkthrough.

### Option B — clone

```powershell
git clone https://github.com/lpaiu-cs/codex-switch.git
cd codex-switch
.\codex-switch.ps1 -Menu
```

Either way, **keep the files together in one folder** — each `.cmd` finds `codex-switch.ps1` next
to itself.

On the first run, your current login is labelled `main` and becomes your first profile. Nothing is
copied or deleted.

### Add a second account

Run the menu, press **`N`**, type a name (`work`, `personal`, …). Codex reopens signed out; log in
with the other account. That's it.

Names allow **1–64** characters: letters, digits, `.`, `-`, `_`. No spaces or slashes.

> [!TIP]
> The login happens in your default browser. If that browser is already signed in to ChatGPT, it
> will happily hand Codex the *same* account again. Sign out on chatgpt.com first, or use a private
> window. From a terminal, `codex login --device-auth` lets you pick the browser yourself.

> [!IMPORTANT]
> Always add an account through **`N`** (a fresh profile), never by running `codex login` while
> another profile is active. `codex login` and `codex logout` revoke the current token on OpenAI's
> side before doing anything else — that would kill the profile you were switching away from.

---

## Everyday use

Double-click any of these:

| File | What it does |
| --- | --- |
| **`시작하기.cmd`** | **Start here.** Checks your setup, explains the options, opens the menu |
| `menu.cmd` | The menu on its own — pick a profile by number, or add one |
| `1-main.cmd` | Jump straight to `main`, then launch Codex |
| `2-work.cmd` | Jump straight to `work`, then launch Codex |
| `list.cmd` | Show profiles with their e-mail / plan, and which one is active |
| `status.cmd` | Who is logged in right now, and how fresh the token is |
| `stop.cmd` | Fully close Codex: the desktop app **and every `codex` CLI session** |

To add a launcher for another profile, copy `2-work.cmd` and change the name inside.

**Switching closes Codex everywhere** — the desktop app, `codex` running in terminals, the VS Code
extension's background server, and anything those sessions were running. Finish or pause in-flight
work first.

<details>
<summary><b>Command line reference</b></summary>

```powershell
.\codex-switch.ps1 <name>            # switch to <name>, then launch the Codex app
.\codex-switch.ps1 <name> -NoLaunch  # switch only (CLI users)
.\codex-switch.ps1 -Menu             # interactive numbered menu
.\codex-switch.ps1 -List             # list profiles (e-mail / plan) and the active one
.\codex-switch.ps1 -Status           # active account, auth mode, last token refresh
.\codex-switch.ps1 -Stop             # fully close the Codex app + every codex.exe
.\codex-switch.ps1 -Version          # print this copy's version
```

Switching to a name that doesn't exist creates an empty profile — the same thing `N` does in the
menu. If the desktop app isn't installed, the launch step is skipped and you just run `codex` in a
terminal. `CODEX_HOME` is honoured; the profile store then lives at `<CODEX_HOME>-profiles`.

</details>

---

## How it works

### A profile is one file

Codex keeps everything under `%USERPROFILE%\.codex` (`CODEX_HOME`), and the desktop app, the CLI
and the VS Code extension all share it. Almost none of it belongs to an account: session
transcripts, the thread index, memories, plugins, skills, `config.toml` carry no account identity.
The one thing that does is **`auth.json`** — the desktop app itself shows whichever account its
background server reads from that file.

So codex-switch never touches your home folder except for that file:

```
%USERPROFILE%\.codex\auth.json                     ← the active profile's login (a real file)
%USERPROFILE%\.codex-profiles\<name>\auth.json     ← parked logins (absent for the active one)
%USERPROFILE%\.codex-profiles\<name>\profile.json  ← e-mail / plan cache for listings
%USERPROFILE%\.codex-profiles\active.txt           ← active marker
```

A switch is: close Codex → move the live `auth.json` into the outgoing profile's folder → move
the target's `auth.json` in → launch. Your threads, memories and settings are the same on every
account because they were never account-specific to begin with.

### Why move, and never copy

The ChatGPT **refresh token rotates every time it is used** — at app launch, every 8 days, and
shortly before the access token expires — and Codex rewrites `auth.json` in place when it does.
A copy taken earlier is therefore a token that has already been spent; restoring it logs you out for
good until you sign in again. codex-switch keeps exactly one `auth.json` per account and moves it,
so a stale copy can't exist. If it ever finds a parked copy where there shouldn't be one, it keeps
the live file and renames the stray to a dated `.bak`.

### Why Codex has to be closed

`auth.json` isn't locked on disk, but Codex caches it in memory and never re-reads it on its own,
rewrites it a few seconds after launch, and that write is a plain truncate-and-rewrite. Swapping
underneath a running Codex would either do nothing or corrupt the file. So `stop.cmd`'s logic runs
before every switch and aborts if anything survives.

<details>
<summary><b>What "stop" matches, and what it leaves alone</b></summary>

Every process is judged on its own image path, then its descendants are swept:

- the Store app: `WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe` and its renderers / helpers
- `codex.exe`, `codex-code-mode-host.exe`, `node.exe`, `node_repl.exe` under `%LOCALAPPDATA%\OpenAI\Codex`
- runtimes under `~\.cache\codex-runtimes` and `~\.codex\bin` / `.sandbox-bin`
- the VS Code extension's bundled `codex.exe`, npm-installed CLIs (`node.exe` running `codex.js`)
- any other `codex.exe` you started in a terminal

**Not** matched: the regular ChatGPT desktop app (`OpenAI.ChatGPT-Desktop`). Its executable is also
named `ChatGPT.exe`, which is exactly why matching is by path, not name. The shell you ran the
script from is protected too, even if Codex spawned it.

</details>

### The account label needs no network

Listings decode the `id_token` inside each `auth.json` locally to show the e-mail, plan and last
refresh time. Nothing is sent anywhere and no quota is used. A parked profile whose last refresh is
older than Codex's 8-day interval is flagged `may need re-login`; usually it still works, Codex just
refreshes it on the next start.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Switch fails with *still running* | Something held on. Run `stop.cmd`, then retry. |
| `cli_auth_credentials_store = "keyring"` error | Codex is set to keep credentials in the OS keyring instead of `auth.json`. Remove that line from `~\.codex\config.toml` (or set it to `"file"`), log in again, retry. |
| Codex opens signed out on a profile that used to work | The refresh token was spent elsewhere (e.g. `codex login`/`logout` ran under that profile, or an old copy of `auth.json` was restored by hand). Log in again once; the profile is repaired. |
| New profile logs in as the *old* account | Your browser's ChatGPT session was reused. Sign out on chatgpt.com or use a private window, then retry `N`. |
| Window flashes and vanishes | You ran it from inside the zip. Extract it to a folder first. |
| `another codex-switch operation is in progress` | A previous run died mid-way. Wait 5 minutes and the stale lock clears itself. |
| Not sure what's going on | Run `status.cmd` (who is logged in) or `list.cmd` (all profiles). |

---

## Safety

- **Never deletes logins.** Switching only *moves* `auth.json`. Nothing else in `~\.codex` is touched.
- **Never calls `codex login` / `codex logout`.** Those revoke tokens server-side.
- **Won't run under a lock.** If Codex can't be closed, the switch aborts before touching files.
- **Rollback on failure.** A failed activation moves the previous login back into place.
- **Store is locked down.** `.codex-profiles` is ACL-restricted to your user account (Codex sets
  no Windows permissions on `auth.json` itself).
- **Name validation** and a **concurrency lock**, same as claude-switch.

## Caveats

- Windows only. Codex desktop (Store) **or** the CLI — either is fine.
- Threads and settings are **shared** across your accounts, by design. Thread titles and transcripts
  from one account are visible in the picker while another is active (locally — they are not sent
  anywhere). A planned `-Isolated` mode will park thread history per profile for people who need
  the separation.
- One account active at a time. This tool makes swapping fast; it doesn't run two at once.
- Relies on Codex's local file layout, which a future release may change.

---

<details>
<summary><b>For maintainers — cutting a release</b></summary>

Versions follow [SemVer](https://semver.org/). `$ScriptVersion` in `codex-switch.ps1` is the single
source of truth, and the tag must match it — the build fails otherwise.

1. Bump `$ScriptVersion` and add the matching `CHANGELOG.md` entry.
2. Commit, then tag and push:
   ```powershell
   git tag -a v1.0.0 -m "codex-switch v1.0.0"
   git push origin v1.0.0
   ```
3. The `Release` workflow builds `dist/codex-switch-<version>.zip`, smoke-tests `-Version`,
   verifies the archive contents, and publishes the GitHub Release with the zip and its `.sha256`.

Build locally without tagging:

```powershell
.\tools\build-release.ps1
```

The archive ships only what an end user needs: `codex-switch.ps1`, the `.cmd` helpers,
`시작하기.cmd`, `사용설명서.md`, `README.md`, `CHANGELOG.md`, `LICENSE`. `docs/`, `tools/` and
`.github/` are excluded.

</details>

## License

[MIT](LICENSE)

<br>

---

<div align="center">

# 한국어

[English](#codex-switch)

**Windows에서 Codex의 ChatGPT 계정을 여러 개 쓰는 도구입니다.**

1초 만에 전환되고, 로그인이 유지되고, 대화 기록과 설정은 그대로 공유됩니다.

</div>

```
=== codex-switch ===
Active: main  me@gmail.com  (plus)

  1) main          me@gmail.com  (plus)  [active]
  2) work          me@company.com  (team)
  N) Add new profile (log in with another account)
  Q) Quit

Select:
```

번호를 고르고 Enter를 누르면 그 계정으로 Codex가 다시 열립니다.

> [!NOTE]
> 비공식 커뮤니티 도구이며 OpenAI와 제휴하거나 승인받은 것이 아닙니다. Codex의 로컬 파일
> `auth.json` 을 옮기는 방식이고, 이 파일의 구조는 릴리스마다 바뀔 수 있습니다. 본인이 가진
> 계정(개인/회사) 사이를 오가는 용도이며, 사용량 제한을 우회하기 위해 여러 계정을 쓰는 것은
> OpenAI 약관 위반입니다. 사용에 따른 책임은 사용자에게 있습니다.

---

## 빠르게 시작하기

**필요한 것:** Windows 10/11 · Codex에 한 번 이상 로그인한 상태. **Codex 데스크톱 앱(Microsoft
Store)** 이든 터미널의 **`codex` CLI** 든 상관없습니다. 둘은 같은 로그인을 공유합니다.

Windows PowerShell 5.1은 이미 컴퓨터에 있습니다. 설치할 것은 없습니다.

### 방법 A — 내려받기 (개발 도구 필요 없음)

1. [최신 릴리스](https://github.com/lpaiu-cs/codex-switch/releases/latest)에서
   `codex-switch-<버전>.zip` 을 받습니다.
2. zip에 마우스 오른쪽 클릭 → **압축 풀기**. zip 안에서 바로 실행하면 동작하지 않습니다.
3. **`시작하기.cmd`** 를 두 번 클릭합니다.

*"Windows가 PC를 보호했습니다"* 창이 뜨면 **추가 정보 → 실행**을 누르세요. 인터넷에서 받은
스크립트에는 항상 나오는 안내입니다.

압축 안에는 터미널을 쓰지 않는 분을 위한 단계별 안내서 **`사용설명서.md`** 도 함께 들어 있습니다.

### 방법 B — clone

```powershell
git clone https://github.com/lpaiu-cs/codex-switch.git
cd codex-switch
.\codex-switch.ps1 -Menu
```

어느 방법이든 **파일은 같은 폴더에 함께 두세요.** 각 `.cmd` 는 자기 옆에 있는 `codex-switch.ps1`
을 찾습니다.

처음 실행하면 지금 로그인된 계정이 `main` 이라는 이름을 받고 첫 번째 프로필이 됩니다. 복사하거나
지우는 것은 없습니다.

### 두 번째 계정 추가하기

메뉴에서 **`N`** 을 누르고 이름(`work`, `personal` 등)을 입력하세요. Codex가 로그아웃 상태로 다시
열리면 다른 계정으로 로그인합니다. 끝입니다.

이름은 **1~64자**의 영문자, 숫자, `.`, `-`, `_` 만 됩니다. 한글·공백·경로 구분자는 안 됩니다.

> [!TIP]
> 로그인은 기본 브라우저에서 진행됩니다. 그 브라우저에 이미 ChatGPT가 로그인돼 있으면 **같은
> 계정**이 그대로 연결됩니다. chatgpt.com 에서 먼저 로그아웃하거나 시크릿 창을 쓰세요. 터미널에서
> `codex login --device-auth` 를 쓰면 브라우저를 직접 고를 수 있습니다.

> [!IMPORTANT]
> 계정 추가는 항상 **`N`**(새 프로필)으로 하세요. 다른 프로필이 활성인 상태에서 `codex login` 을
> 실행하면 안 됩니다. `codex login` 과 `codex logout` 은 시작하자마자 현재 토큰을 OpenAI 서버에서
> 폐기하기 때문에, 방금까지 쓰던 프로필이 죽습니다.

---

## 평소 사용법

아래 파일을 두 번 클릭하면 됩니다.

| 파일 | 하는 일 |
| --- | --- |
| **`시작하기.cmd`** | **여기서 시작.** 환경을 확인하고 사용법을 안내한 뒤 메뉴를 띄웁니다 |
| `menu.cmd` | 메뉴만 띄우기 — 번호로 프로필 선택 또는 추가 |
| `1-main.cmd` | `main` 으로 바로 전환하고 Codex 실행 |
| `2-work.cmd` | `work` 으로 바로 전환하고 Codex 실행 |
| `list.cmd` | 프로필 목록(이메일·플랜)과 현재 활성 프로필 표시 |
| `status.cmd` | 지금 로그인된 계정과 토큰 갱신 시각 표시 |
| `stop.cmd` | Codex 완전 종료 — 데스크톱 앱과 **모든 `codex` CLI 세션** |

다른 프로필용 실행기가 필요하면 `2-work.cmd` 를 복사해 안의 이름만 바꾸세요.

**전환하면 Codex가 전부 닫힙니다.** 데스크톱 앱, 터미널의 `codex`, VS Code 확장의 백그라운드
서버, 그리고 그 세션들이 실행 중이던 작업까지. 진행 중인 작업은 먼저 마무리하세요.

<details>
<summary><b>명령줄 사용법</b></summary>

```powershell
.\codex-switch.ps1 <이름>            # <이름>으로 전환 후 Codex 앱 실행
.\codex-switch.ps1 <이름> -NoLaunch  # 전환만 (CLI 사용자)
.\codex-switch.ps1 -Menu             # 번호 선택 메뉴
.\codex-switch.ps1 -List             # 프로필 목록(이메일·플랜)과 활성 프로필
.\codex-switch.ps1 -Status           # 활성 계정, 인증 방식, 마지막 토큰 갱신
.\codex-switch.ps1 -Stop             # Codex 앱 + 모든 codex.exe 완전 종료
.\codex-switch.ps1 -Version          # 버전 출력
```

없는 이름으로 전환하면 빈 프로필이 만들어집니다. 메뉴의 `N` 과 같습니다. 데스크톱 앱이 없으면
실행 단계만 건너뛰며, 터미널에서 `codex` 를 실행하면 됩니다. `CODEX_HOME` 을 설정했다면 프로필
저장소는 `<CODEX_HOME>-profiles` 에 생깁니다.

</details>

---

## 동작 원리

### 프로필은 파일 하나

Codex는 모든 것을 `%USERPROFILE%\.codex`(`CODEX_HOME`)에 두고, 데스크톱 앱·CLI·VS Code 확장이
이 폴더를 함께 씁니다. 그런데 이 안에서 계정에 묶인 것은 거의 없습니다. 대화 기록, 스레드 인덱스,
메모리, 플러그인, 스킬, `config.toml` 어디에도 계정 식별자가 없습니다. 유일하게 계정에 묶인 것이
**`auth.json`** 이고, 데스크톱 앱이 보여 주는 계정도 백그라운드 서버가 이 파일에서 읽은 것입니다.

그래서 codex-switch는 홈 폴더에서 이 파일 하나만 건드립니다.

```
%USERPROFILE%\.codex\auth.json                     ← 활성 프로필의 로그인 (실제 파일)
%USERPROFILE%\.codex-profiles\<이름>\auth.json     ← 보관 중인 로그인 (활성 프로필에는 없음)
%USERPROFILE%\.codex-profiles\<이름>\profile.json  ← 목록 표시용 이메일·플랜 캐시
%USERPROFILE%\.codex-profiles\active.txt           ← 활성 마커
```

전환은 "Codex 종료 → 라이브 `auth.json` 을 나가는 프로필 폴더로 이동 → 대상 프로필의
`auth.json` 을 라이브로 이동 → 실행" 입니다. 대화·메모리·설정은 원래 계정별이 아니었기 때문에
어느 계정에서나 그대로입니다.

### 왜 복사하지 않고 이동하는가

ChatGPT **refresh token 은 쓸 때마다 바뀝니다.** 앱 실행 시, 8일마다, access token 만료 직전에
갱신되고 Codex는 그때마다 `auth.json` 을 제자리에서 다시 씁니다. 그러니 미리 떠 둔 복사본은 이미
사용된 토큰이고, 그걸 되돌리면 다시 로그인할 때까지 그 계정은 죽은 상태가 됩니다. codex-switch는
계정당 `auth.json` 을 정확히 하나만 두고 이동만 하므로 오래된 복사본이 생길 수 없습니다. 있어서는
안 될 자리에서 보관 파일이 발견되면 라이브 파일을 우선하고 그 파일은 날짜가 붙은 `.bak` 으로
남깁니다.

### 왜 Codex를 닫아야 하는가

`auth.json` 은 디스크에서 잠기지 않지만, Codex는 이 파일을 메모리에 캐시하고 스스로 다시 읽지
않습니다. 실행 몇 초 뒤 파일을 다시 쓰는데 그 쓰기는 단순한 잘라내기 후 덮어쓰기입니다. 실행 중에
바꿔치기하면 효과가 없거나 파일이 깨집니다. 그래서 모든 전환 전에 `stop.cmd` 와 같은 로직이
돌고, 하나라도 남아 있으면 중단합니다.

<details>
<summary><b>"종료"가 잡는 것과 놔두는 것</b></summary>

각 프로세스를 자기 실행 파일 경로로 판정하고, 그 자손을 모두 쓸어 담습니다.

- Store 앱: `WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe` 와 렌더러·헬퍼
- `%LOCALAPPDATA%\OpenAI\Codex` 아래의 `codex.exe`, `codex-code-mode-host.exe`, `node.exe`, `node_repl.exe`
- `~\.cache\codex-runtimes`, `~\.codex\bin`, `.sandbox-bin` 아래의 런타임
- VS Code 확장이 번들한 `codex.exe`, npm 설치 CLI(`codex.js` 를 돌리는 `node.exe`)
- 터미널에서 직접 실행한 그 밖의 `codex.exe`

일반 ChatGPT 데스크톱 앱(`OpenAI.ChatGPT-Desktop`)은 **잡지 않습니다.** 실행 파일 이름이 똑같이
`ChatGPT.exe` 라서, 이름이 아니라 경로로 판정하는 이유가 바로 이것입니다. 스크립트를 실행한 셸도
Codex가 띄운 것이든 아니든 보호됩니다.

</details>

### 계정 표시에 네트워크가 필요 없음

목록은 각 `auth.json` 안의 `id_token` 을 로컬에서 디코드해 이메일·플랜·마지막 갱신 시각을
보여 줍니다. 어디로도 전송되지 않고 사용량도 쓰지 않습니다. 마지막 갱신이 Codex의 8일 주기를
넘긴 보관 프로필은 `may need re-login` 으로 표시되는데, 보통은 그대로 동작하고 Codex가 다음
실행 때 갱신합니다.

---

## 문제 해결

| 증상 | 해결 |
| --- | --- |
| *still running* 오류로 전환 실패 | 무언가 남아 있습니다. `stop.cmd` 를 실행한 뒤 다시 시도하세요. |
| `cli_auth_credentials_store = "keyring"` 오류 | Codex가 자격증명을 `auth.json` 대신 OS 키링에 두도록 설정돼 있습니다. `~\.codex\config.toml` 에서 그 줄을 지우거나 `"file"` 로 바꾸고, 다시 로그인한 뒤 재시도하세요. |
| 잘 되던 프로필인데 Codex가 로그아웃 상태로 열림 | refresh token 이 다른 곳에서 소모됐습니다(그 프로필에서 `codex login`/`logout` 을 실행했거나, 예전 `auth.json` 복사본을 수동으로 되돌린 경우). 한 번 다시 로그인하면 프로필이 복구됩니다. |
| 새 프로필인데 *예전* 계정으로 로그인됨 | 브라우저의 ChatGPT 세션이 재사용됐습니다. chatgpt.com 에서 로그아웃하거나 시크릿 창을 쓰고 `N` 을 다시 하세요. |
| 창이 열렸다가 바로 사라짐 | zip 안에서 실행한 경우입니다. 폴더로 압축을 푼 뒤 실행하세요. |
| `another codex-switch operation is in progress` | 이전 실행이 도중에 죽었습니다. 5분 기다리면 오래된 락이 자동으로 풀립니다. |
| 뭐가 뭔지 모르겠음 | `status.cmd`(지금 로그인된 계정) 또는 `list.cmd`(전체 프로필)를 실행해 보세요. |

---

## 안전장치

- **로그인을 지우지 않습니다.** 전환은 `auth.json` 을 *이동*만 합니다. `~\.codex` 의 다른 파일은 건드리지 않습니다.
- **`codex login` / `codex logout` 을 대신 실행하지 않습니다.** 서버에서 토큰을 폐기하는 명령입니다.
- **잠긴 상태에서는 실행하지 않습니다.** Codex를 닫지 못하면 파일을 건드리기 전에 중단합니다.
- **실패 시 롤백.** 활성화에 실패하면 이전 로그인을 제자리로 되돌립니다.
- **저장소 권한 제한.** `.codex-profiles` 는 현재 사용자 계정만 접근하도록 ACL을 설정합니다(Codex 자체는 `auth.json` 에 Windows 권한을 설정하지 않습니다).
- **이름 검증**과 **동시 실행 락**은 claude-switch와 같습니다.

## 알아둘 점

- Windows 전용. Codex 데스크톱(Store) **또는** CLI, 어느 쪽이든 됩니다.
- 대화와 설정은 계정 간에 **공유**됩니다. 설계상 그렇습니다. 한 계정의 대화 제목과 본문이 다른
  계정이 활성일 때도 목록에 보입니다(로컬 파일이며 어디로도 전송되지 않습니다). 분리가 필요한
  분을 위해 대화 기록을 프로필별로 보관하는 `-Isolated` 모드를 후속으로 계획하고 있습니다.
- 한 번에 하나의 계정만 활성입니다. 빠르게 바꿔 주는 도구이지 동시에 둘을 띄우는 도구는 아닙니다.
- Codex의 로컬 파일 구조에 의존하며, 향후 릴리스에서 바뀔 수 있습니다.

## 라이선스

[MIT](LICENSE)
