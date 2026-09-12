# codex-switch 설계

Windows에서 Codex(데스크톱 앱 + CLI + IDE 확장)의 ChatGPT 계정을 여러 개 유지하고 1초 안에
전환하는 도구(macOS 이식은 §9). [claude-switch](https://github.com/lpaiu-cs/claude-switch)와 같은 사용자 경험
(메뉴, `.cmd` 런처, `-Stop`, 롤백, 락)을 제공하되, 내부 구조는 두 하네스의 차이에 맞춰 다시 설계한다.

작성일 2026-09-08. 조사 대상: Codex CLI 0.151.0, Codex 데스크톱 26.901.6511.0 (MSIX), 로컬 확인 + 소스 조사.

---

## 1. 두 하네스의 차이 (설계를 가르는 사실)

| 항목 | Claude Desktop | Codex | 설계 영향 |
| --- | --- | --- | --- |
| 계정 데이터 위치 | `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude` (MSIX 가상화 폴더, 그 자체가 정션) | `%USERPROFILE%\.codex` (`CODEX_HOME`). MSIX 가상화 밖. CLI·앱·VS Code 확장이 **같은 폴더 공유** | 프로필 저장소를 `.codex` 밖 일반 경로에 두면 됨. 앱 없이 CLI만 쓰는 사용자도 지원 가능 |
| 계정에 묶인 데이터 | 세션이 `claude-code-sessions\<accountUuid>\<orgUuid>` 로 계정별 분리. 폴더 전체가 계정 종속 | **`auth.json` 한 파일**. rollout jsonl 헤더, sqlite 스키마 어디에도 계정 식별자 없음(로컬 확인). 앱 UI 계정도 app-server `account/read` = auth.json | **폴더 이동이 아니라 파일 하나 교체**. 세션·메모리·플러그인은 자동 공유 → claude-switch의 cc-sync 같은 세션 동기화가 불필요 |
| 무거운 공용 자산 | `vm_bundles` 11 GB 를 정션으로 공유 | `plugins/` 438 MB, `packages/` 395 MB, `sessions/` 1.2 GB 등이 모두 계정 중립이며 `.codex` 에 그대로 남음 | 정션 불필요. 정션을 쓰면 `CODEX_HOME` 이 `canonicalize()` 되어 `\\?\` 경로로 바뀌는 부작용도 피함 |
| 원자적 쓰기 | 앱이 tmp→rename. 이중 정션에서 ENOENT | `auth.json` 은 **truncate 후 in-place 덮어쓰기(비원자적)**. 잠금 없음. 앱은 실행 ~4초 뒤 `auth.json` 을 다시 씀 | 우리가 쓰는 쪽은 tmp→rename 으로 더 안전하게. 교체는 반드시 프로세스 정지 후 |
| 자격증명 수명 | 로그인 상태가 폴더 안에 통째로 | **refresh token 이 사용 시 회전(1회용)**. 8일 또는 만료 5분 전에 갱신. 오래된 복사본은 영구 사망 | **복사본을 만들지 말고 이동**한다. 활성 프로필의 진실은 항상 라이브 파일 |
| 로그아웃 | 폴더 이동만으로 처리 | `codex logout` 은 서버에 revoke 호출 → 저장해 둔 프로필도 죽음 | 도구는 절대 `codex logout` 을 호출하지 않는다. README 에 경고 |
| 대체 저장소 | 없음 | `cli_auth_credentials_store = keyring|auto` 면 auth.json 이 삭제되고 OS 키링 사용. 키는 `CODEX_HOME` 경로 해시라 프로필 간 충돌 | 이 설정이면 실행 거부하고 `file` 로 바꾸라고 안내 |
| 프로세스 | 패키지 exe 이름이 `Claude*`. 자식은 정션 폴더에서 실행 | 패키지 exe 가 **`ChatGPT.exe`** (`WindowsApps\OpenAI.Codex_*`). 형제 패키지 `OpenAI.ChatGPT-Desktop` 도 같은 이름 계열. CLI 는 `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`, 런타임은 `...\OpenAI\Codex\runtimes\`, `~\.cache\codex-runtimes\`, `~\.codex\.sandbox-bin\`. 터미널·VS Code 에서 뜬 `codex.exe` 는 앱의 자식이 아님 | 이름이 아니라 **이미지 경로**로 매칭. 앱 트리 외에 독립 CLI 인스턴스도 모두 정지. `OpenAI.ChatGPT-Desktop` 은 건드리지 않음 |
| 파일 잠금 | 자식이 Live 안 파일 잡음 | `state_5.sqlite`, `logs_2.sqlite`, `queue_1.sqlite`, `sqlite\codex-dev.db` 가 앱 실행 중 잠김. `auth.json` 은 잠기지 않음 | 파일 교체 자체는 잠금과 무관하지만, 메모리 캐시된 auth 와 실행 직후 재쓰기 때문에 정지는 필수 |
| 계정 표시 | 폴더명뿐. 이메일은 수동 라벨 | `id_token` JWT 에 `email`, `name`, `chatgpt_plan_type`, `chatgpt_account_id` 가 있음 (네트워크 불필요) | 목록에 이메일·플랜 자동 표시 |
| 실행 | `shell:AppsFolder\<pfn>!Claude` | `shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App`. 앱이 없으면 CLI-only | 패키지 없으면 실행 단계만 건너뜀 |
| 환경변수 우회 | 없음 | `CODEX_HOME` 을 앱(app.asar)·CLI 모두 존중 | 검토 후 **불채택** (아래 §6) |

---

## 2. 레이아웃

```
%USERPROFILE%\.codex\                        공유 홈. 건드리지 않음 (config, sessions, plugins, sqlite ...)
%USERPROFILE%\.codex\auth.json               = 활성 프로필의 자격증명 (실제 파일)
%USERPROFILE%\.codex-profiles\<name>\auth.json   비활성 프로필 (활성 프로필 폴더에는 auth.json 이 없음)
%USERPROFILE%\.codex-profiles\<name>\profile.json  {email, plan, accountId, savedAt}  표시용 캐시
%USERPROFILE%\.codex-profiles\active.txt     활성 프로필 마커
%USERPROFILE%\.codex-profiles\codex-switch.lock
```

- 저장소를 `.codex` **밖**에 둔다. Codex 가 `.codex` 트리를 스캔하며, `<name>.config.toml` 프로필 오버레이와 이름 충돌 가능성도 피한다.
- 프로필 폴더 ACL 은 현재 사용자만 접근하도록 `icacls /inheritance:r /grant:r "%USERNAME%":(OI)(CI)F`. auth.json 은 평문 bearer 토큰인데 Codex 자체는 Windows ACL 을 설정하지 않는다.
- 활성 프로필 폴더에는 `auth.json` 이 **없다**(이동 기반). 이것이 "복사본 = 죽은 토큰" 사고를 구조적으로 막는다.

## 3. 전환 알고리즘

```
switch <target>:
  1. 이름 검증 (claude-switch 와 동일 규칙)  ->  락 획득
  2. 사전 점검: config.toml 의 cli_auth_credentials_store 가 keyring/auto 면 중단
  3. Stop-Codex  (앱 트리 + 모든 독립 codex.exe. 실패하면 파일 손대기 전에 중단)
  4. active = 마커.  active == target 이면 5 건너뜀
  5. 스태시: .codex\auth.json 이 있으면
        -> profile.json 갱신 (id_token 디코드)
        -> tmp 로 복사 후 rename 으로 .codex-profiles\<active>\auth.json 에 놓고 원본 삭제
     .codex\auth.json 이 없으면 (사용자가 codex logout 했거나 미로그인) 프로필을 "logged-out" 으로 표시만 함
  6. 활성화: .codex-profiles\<target>\auth.json 이 있으면 라이브로 이동 (tmp→rename)
             없으면 새 프로필. 라이브에 auth.json 없는 상태로 두고 "실행 후 로그인하세요" 안내
  7. 실패 시 롤백: 5 에서 스태시한 파일을 라이브로 되돌리고 마커 복구
  8. 마커 = target.  Codex 앱 실행 (-NoLaunch 아니면, 패키지가 있을 때만)
```

한 번의 전환에서 움직이는 것은 4 KB 파일 하나뿐이다. 정지·재실행 시간만 남는다.

### 왜 "이동"인가

refresh token 은 1회용이다. 활성 계정이 쓰는 동안 저장소에 복사본이 남아 있으면, 크래시나 사용자 실수로 그 복사본이 복원되는 순간 "refresh token was already used" 로 프로필이 죽는다. 라이브 파일이 유일한 진실이 되도록 이동만 한다. 손상 대비는 스태시 직전 라이브 파일의 `.bak` 한 세대를 프로필 폴더에 남기는 정도로 충분하다(복원은 사용자가 명시적으로 할 때만).

## 4. Stop-Codex (프로세스 정지)

**2026-09-09 수정.** 데스크톱 앱은 `Stop-Process` 로 하나씩 죽이지 않는다. 실측 결과 Codex 의 MSIX 컨테이너는 개별 강제 종료와 해체가 경쟁하면 깨진다: AppModel-Runtime 로그에 "Destroyed Desktop AppX container" 가 0.1초에 600여 건 찍히고, 패키지는 계속 "실행 중"(재등록 시 0x80073D02) 으로 남으며, 이후 모든 활성화는 모듈 0개·스레드 suspended 인 `ChatGPT.exe` 스텁으로 영원히 멈춘다(로그아웃 전까지). 좀비 핸들, 샌드박스 사용자 프로세스, 잠긴 hive 는 모두 배제됐다. 해법은 Windows 가 쓰는 경로로 닫는 것: `Add-AppxPackage -Register -DisableDevelopmentMode -ForceApplicationShutdown <InstallLocation>\AppxManifest.xml`. 컨테이너 전체(앱 + app-server 자식)를 순서대로 종료·해체하며 약 0.4초, 같은 버전 재등록이라 데이터 영향 없음. 같은 호출이 이미 깨진 상태도 복구한다. 실행 후 8초 안에 모듈이 로드된 프로세스가 보이지 않으면 스텁 제거 → 위 호출 → 1회 재시도한다.

컨테이너 밖의 프로세스(터미널 CLI, VS Code 확장, npm 설치본)에는 claude-switch 의 "프로세스별 자기 증거로 루트 판정 → 부모 맵으로 자손 수집 → PID 로 종료 확인" 구조를 그대로 쓰되 루트 술어만 바꾼다.

루트 판정 (ExecutablePath 기준):
- `*\WindowsApps\OpenAI.Codex_*` (앱 본체 `ChatGPT.exe`, 렌더러, crashpad, 번들 `codex.exe`)
- `%LOCALAPPDATA%\OpenAI\Codex\*` (`codex.exe`, `node.exe`, `node_repl.exe`, `codex-code-mode-host.exe`, `codex-command-runner.exe`)
- `%USERPROFILE%\.cache\codex-runtimes\*` (런타임 `pwsh.exe` 등)
- `%USERPROFILE%\.codex\bin\*`, `%USERPROFILE%\.codex\.sandbox-bin\*` (앱이 홈 안에 materialize 하는 `codex.exe`, `codex-command-runner.exe`)
- `*\.vscode\extensions\openai.chatgpt-*\bin\*` (VS Code 확장이 번들한 `codex.exe … app-server`)
- `*\node_modules\@openai\codex*\vendor\*\bin\codex.exe` (npm 설치 CLI) 와 그 부모인 `node.exe`(커맨드라인에 `codex.js`). npm 셤은 spawn 이라 두 프로세스가 뜬다
- 위 경로들의 `codex.exe` 는 sandbox·apply-patch 헬퍼로 자기 자신을 재호출하므로 이미지 경로 매칭으로 모두 잡힌다

제외:
- `*\WindowsApps\OpenAI.ChatGPT-Desktop_*` (일반 ChatGPT 앱. 같은 exe 이름 계열이므로 이름 매칭을 쓰면 오살한다)
- 자기 자신 `$PID` 와 그 조상. Codex 가 띄운 셸에서 실행됐을 때 자살 방지

메뉴와 README 에 "터미널·VS Code 에서 돌던 codex 세션도 함께 닫힌다" 를 명시한다.

## 5. 사용자 인터페이스 (claude-switch 와 동일 외형)

```
=== codex-switch ===
Active: work   me@company.com  (team)

  1) main   me@gmail.com      (plus)
  2) work   me@company.com    (team)   [active]
  3) old    (logged out - login after launch)
  N) Add new profile
  Q) Quit
```

CLI: `codex-switch.ps1 <name> [-NoLaunch]`, `-Menu`, `-List`, `-Stop`, `-Status`, `-Version`.
`-Status` 는 `codex login status` 대신 `id_token` 을 디코드해 이메일·플랜·`last_refresh` 경과일을 보여 준다.
`last_refresh` 가 8일을 넘긴 비활성 프로필은 목록에 `(may need re-login)` 표시.

런처: `시작하기.cmd`, `menu.cmd`, `list.cmd`, `stop.cmd`, `1-main.cmd`, `2-work.cmd`. 파일 구성과 릴리스
파이프라인(`tools/build-release.ps1`, GitHub Actions, `$ScriptVersion` 단일 소스)은 claude-switch 에서 가져온다.

### 새 계정 추가 흐름

`N` → 이름 입력 → 활성 auth.json 스태시 → 라이브에 auth.json 없음 → 앱 실행 → 앱이 로그인 화면을 띄움 → 브라우저 로그인.
주의 사항: 앱 userData 의 쿠키는 Cloudflare 쿠키뿐임을 확인했지만, 브라우저 로그인은 사용자의 기본 브라우저에서
일어나므로 이미 로그인된 ChatGPT 웹 세션이 재사용될 수 있다. README 에 "다른 계정으로 로그인하려면 브라우저에서
먼저 로그아웃하거나 시크릿 창을 쓰세요" 를 적는다. `codex login --device-auth` 를 대안으로 안내.

### `codex login` 은 새 프로필에서만

모든 `codex login` 경로는 먼저 기존 자격증명을 **서버 측 revoke** 하고 지운다(`clear_existing_auth_before_login`).
활성 프로필이 있는 상태에서 다른 계정으로 `codex login` 하면 그 프로필의 refresh token 이 죽는다. 그래서
"계정 추가"는 반드시 `N`(빈 프로필로 전환) → 로그인 순서여야 하며, README 와 메뉴 안내문에 이 순서를 못박는다.
같은 이유로 도구는 `codex login`/`codex logout` 을 절대 대신 실행하지 않고, 복구는 파일 이동으로만 한다.

## 6. 검토 후 버린 대안

- **폴더 전체 이동(claude-switch 방식)**: 계정 종속 데이터가 없으므로 2 GB 이상을 매번 옮길 이유가 없고, 앱이 잡고 있는 sqlite 핸들과 `thread-writer-locks\*.lock` 때문에 정지 실패 시 이동이 깨진다. `state_5.sqlite` 의 `threads.rollout_path` 가 절대경로라 홈 경로가 바뀌면 인덱스도 어긋난다. 단, 공유 방식의 대가는 있다. 스레드 목록·`codex resume` 이 계정을 구분하지 않으므로 A 계정의 대화 제목과 본문이 B 계정에서도 보인다(로컬 파일이라 서버로 새지는 않음). 회사/개인 분리가 필요한 사용자를 위해 후속 옵션 `-Isolated`(`sessions/`, `archived_sessions/`, `session_index.jsonl`, `thread_history_1.sqlite`, `state_5.sqlite`, `memories/`, `history.jsonl` 을 프로필별로 이동. `bin/`, `secrets/`, `plugins/`, `packages/` 는 공유 유지)을 남긴다. 기본값은 공유.
- **`CODEX_HOME` 환경변수로 포인터 전환**: 앱·CLI 모두 지원하지만 사용자 수준 env 변경은 이미 열린 터미널·VS Code 에 전파되지 않아 두 계정이 동시에 다른 홈을 쓰는 상태가 생긴다. config.toml 안의 MCP env 에도 절대경로가 박혀 있다. 단일 정본 경로를 유지하는 이동 방식이 낫다.
- **정션**: 필요 없고, `canonicalize()` 로 `\\?\` 경로가 되는 부작용과 커뮤니티에서 반례가 보고돼 있다.
- **auth.json 복사 + 저장소 원본 유지**: 회전 토큰 때문에 죽은 복사본이 남는다.

## 7. 경계·주의

- OpenAI 는 계정 여러 개 보유와 웹 계정 전환을 공식 지원하지만 Codex 데스크톱에서의 전환은 미지원이다. README 에 "본인 소유 계정(개인/회사) 간 전환 편의 도구이며 사용량 제한 우회 목적이 아님" 과 회사 계정은 회사 정책을 따른다는 면책을 적는다.
- `~/.codex` 내부 구조는 비공개이며 릴리스마다 바뀐다(`history.jsonl` 은 이미 사라졌고, `[profiles.*]` 는 `<name>.config.toml` 오버레이로 바뀜). 도구가 의존하는 것은 `auth.json` 경로와 `id_token` 클레임 두 가지뿐이라 표면적이 작다.
- Codex 의 `--profile` 은 `<name>.config.toml` 설정 오버레이일 뿐 자격증명과 무관하다(구 `[profiles.*]` 도 마찬가지). 이름이 겹쳐 혼동되므로 README 에서 구분한다.
- 계정 전환에 `OPENAI_API_KEY` 는 관여하지 않는다. 자격증명 우선순위는 `CODEX_API_KEY` env → 임시 저장소 → `CODEX_ACCESS_TOKEN` env → `auth.json` 이다. 셸 단위로 다른 API 키를 쓰고 싶은 사용자에겐 `CODEX_API_KEY` 를 안내한다.
- `codex login status` 는 stderr 에 인증 방식만 출력하고 이메일·플랜은 안 나온다. 그래서 `-Status` 는 JWT 디코드로 구현한다.

### 참고한 커뮤니티 구현

가장 가까운 레퍼런스는 [Lampese/codex-switcher](https://github.com/Lampese/codex-switcher)(auth.json 교체, 앱 정지, 토큰 회전 명시적 처리)와
[enerai/codex-auth-snap](https://github.com/enerai/codex-auth-snap)(PowerShell, ACL 강화, reparse point 거부). 공식 이슈
[openai/codex#4432](https://github.com/openai/codex/issues/4432), [#30684](https://github.com/openai/codex/issues/30684) 는 미해결이다.

## 8. 구현 순서

1. `codex-switch.ps1` 골격: 경로 해석(`CODEX_HOME` 존중, 앱 패키지는 선택), 락, 이름 검증, 마커.
2. `Get-CodexProcesses` / `Stop-Codex` — 루트 술어와 제외 규칙, PID 기반 종료 확인.
3. `Read-AuthIdentity` (JWT base64url 디코드) 와 `profile.json`.
4. 전환 본체(스태시 → 활성화 → 롤백) + keyring 설정 사전 점검.
5. `-Menu`, `-List`, `-Status`, `.cmd` 런처, `시작하기.cmd`.
6. 검증 시나리오: (a) 두 계정 왕복 후 각 계정에서 `codex login status` 와 앱 계정 표시 확인, (b) 전환 후 refresh 발생(앱 실행 4초 뒤 `last_refresh` 갱신) 뒤 다시 돌아와도 로그인 유지, (c) 터미널 `codex` 실행 중 전환 시 정지·안내, (d) 앱 미설치 환경에서 CLI-only 동작, (e) 8일 이상 묵힌 프로필 재로그인 안내.
7. README(영/한), `사용설명서.md`, CHANGELOG, 릴리스 워크플로 이식.

---

## 9. macOS 이식 (1.1.0)

작성일 2026-09-12. 조사 대상: Codex 데스크톱 26.831.21537(`/Applications/ChatGPT.app`), 로컬 확인.

계정 데이터 쪽은 이식할 것이 없었다. `CODEX_HOME` 기본값이 `~/.codex` 로 같고, `auth.json` 구조
(`auth_mode`, `last_refresh`, `tokens.id_token`)도 같고, 앱 번들 안의 `Contents/Resources/codex`
가 그대로 app-server 다(바이너리에서 `CODEX_HOME`·`auth.json` 문자열 확인). 그래서 §2 레이아웃과
§3 전환 알고리즘은 한 글자도 바뀌지 않는다. 다시 쓴 것은 OS 표면뿐이다.

| 항목 | Windows | macOS |
| --- | --- | --- |
| 앱 식별 | 패키지 `OpenAI.Codex` | 번들 ID `com.openai.codex` (디스크 이름은 `ChatGPT.app`) |
| 건드리면 안 되는 형제 앱 | `OpenAI.ChatGPT-Desktop` | `com.openai.chat` (`ChatGPT Classic.app`) |
| 정지 | AppX 배포 API로 컨테이너 종료 | 컨테이너 없음 → SIGTERM 후 SIGKILL |
| 실행 | `shell:AppsFolder\<aumid>` | `open -b com.openai.codex` |
| 저장소 권한 | `icacls` | `chmod 700` (Codex가 auth.json 을 이미 0600으로 씀) |
| JSON·JWT | `ConvertFrom-Json` | `plutil` + `base64 -D` |

**프로세스 매칭.** 루트 판정 원칙은 그대로 "각 프로세스의 자기 실행 경로"다. 번들 경로,
`$CODEX_HOME/*`, `~/.cache/codex-runtimes/*`, VS Code 확장, npm 설치본, 그리고 basename
(`codex`, `codex-app-server`, `codex-command-runner` …). 여기에 macOS 고유로 두 가지를 더한다.

- `*/Codex Framework.framework/*` — Electron 프레임워크 이름이 제품명을 따른다. 일반 ChatGPT 앱은
  `ChatGPT.framework` 라서 오살 위험이 없고, 앱이 다른 위치에 있거나 이름이 바뀌어도 잡힌다.
  실제로 테스트 머신에는 이름이 바뀌기 전 `Codex.app`(149.x)의 crashpad 프로세스가 남아 있었고,
  이 규칙으로만 잡혔다.
- 매칭된 경로에서 번들 루트(`…/Foo.app`)를 역산해 같은 번들의 나머지 프로세스도 넣는다. 앱 본체는
  헬퍼의 **부모**라서 자손 스윕만으로는 놓치고, 놓치면 살아 있는 앱 밑에서 `auth.json` 을 바꾸게
  된다 — §1과 §3이 금지하는 바로 그 상황이다.

**정지 방식.** MSIX 컨테이너가 없으니 1.0.1의 패키지 종료·스텁 복구는 대응물 자체가 없다. SIGTERM
을 먼저 보내 앱이 상태를 정리할 기회를 주고, 2초 뒤에도 남은 것만 SIGKILL 한다. 본 PID 기준으로
확인하는 검증 루프는 그대로다.

**도구 선택.** `plutil` 은 모든 Mac 에 있고 JSON 을 읽으므로 jq·python 의존이 생기지 않는다. 다만
`plutil -lint` 는 plist 전용이라 정상 JSON 을 거부한다 — 유효성 검사는
`plutil -convert json -o /dev/null` 로 한다. `id_token` 클레임의 `https://api.openai.com/auth` 는
키 이름에 점이 있어 keypath 로 꺼낼 수 없으므로, 디코드된 한 줄 JSON 에서 `sed` 로 두 필드만 뽑는다.

**락.** `set -o noclobber` + 리다이렉트(= `O_EXCL`)로 Windows 판과 같은 파일 이름을 쓴다. mkdir 락
으로 하면 저장소 목록에 디렉터리 하나가 프로필처럼 섞인다.

**검증.** `tools/test-codex-switch.sh` 가 버리는 `CODEX_HOME` 에 대고 스태시·활성화, 실패 시 롤백,
`id_token` 디코드, 이름 검증, keyring 거부를 확인한다(프로세스는 건드리지 않는다). 릴리스
워크플로가 macOS 잡에서 이것과 두 스크립트의 버전 일치를 먼저 돌리고, 통과해야 zip 을 만든다.

### 검토 후 버린 대안

- **`codex-switch.ps1` 을 pwsh 로 크로스플랫폼화**: 4 KB 파일 하나 옮기자고 PowerShell 7 설치를
  요구하게 된다. 정지·실행·권한은 어차피 플랫폼별 분기라 공유되는 것은 알고리즘뿐이고, 그
  알고리즘의 정본은 코드가 아니라 이 문서다.
- **`시작하기.command` 더블클릭 런처**: zip 은 실행 권한을 보존하지 않아 Finder 더블클릭은 받는
  즉시 실패한다. 권한을 주려면 어차피 터미널을 열어야 하니, 터미널 한 줄로 안내하는 편이 정직하다.
- **Linux**: CLI 경로는 비슷하지만 데스크톱 앱·프로세스 트리를 확인할 환경이 없어 넣지 않았다.
  넣는다면 `is_codex_path` 의 번들 규칙만 교체하면 된다.
