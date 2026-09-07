Windows에서 **Codex(데스크톱 앱 · CLI · VS Code 확장)의 여러 ChatGPT 계정을 번갈아 쓰는** 도구입니다.
계정을 바꿔도 로그인이 유지되고, 대화 기록과 설정은 그대로 공유됩니다.

---

## 컴퓨터를 잘 모르신다면 (설치 방법)

1. 아래 **Assets** 에서 **`codex-switch-{{VERSION}}.zip`** 을 클릭해 내려받으세요.
2. 내려받은 zip 파일에 **마우스 오른쪽 클릭 → 압축 풀기**
   - 압축을 풀지 않고 안에서 바로 실행하면 동작하지 않습니다.
3. 압축을 푼 폴더에서 **`시작하기.cmd`** 를 두 번 클릭하세요.
   - "Windows가 PC를 보호했습니다" 창이 뜨면 **추가 정보 → 실행** 을 누르세요. 정상입니다.
4. 번호를 골라 Enter를 누르면 계정이 바뀌고 Codex가 열립니다.

자세한 설명은 압축 안의 **`사용설명서.md`** 에 있습니다.

> 계정을 바꾸면 **Codex 앱과 터미널에서 실행 중인 codex 세션이 모두 닫힙니다.**
> 진행 중인 작업이 있으면 먼저 마무리하세요.

### 필요한 것

- Windows 10 / 11
- Codex 에 한 번 이상 로그인한 상태 (Microsoft Store 앱 또는 터미널 CLI 어느 쪽이든)
- Windows PowerShell 5.1 (Windows에 기본 포함 — 따로 설치할 필요 없습니다)

---

## For developers

Download `codex-switch-{{VERSION}}.zip`, extract it anywhere, and run `menu.cmd` or call
`codex-switch.ps1` directly. `codex-switch.ps1 -Version` reports the version.

```powershell
.\codex-switch.ps1 <name>            # switch to <name>, then launch Codex
.\codex-switch.ps1 -List             # list profiles (e-mail / plan) and the active one
.\codex-switch.ps1 -Status           # active account, auth mode, token freshness
.\codex-switch.ps1 -Menu             # interactive numbered menu
.\codex-switch.ps1 -Stop             # close the Codex app + every codex.exe
```

Verify the download:

```powershell
Get-FileHash .\codex-switch-{{VERSION}}.zip -Algorithm SHA256
```

Compare against `codex-switch-{{VERSION}}.zip.sha256`.

Full change list: [CHANGELOG.md](https://github.com/lpaiu-cs/codex-switch/blob/v{{VERSION}}/CHANGELOG.md)

---

Unofficial community tool, not affiliated with or endorsed by OpenAI. It moves Codex's local
`auth.json`, an undocumented file that can change between releases. Intended for switching between
your own accounts (e.g. personal and work), not for circumventing usage limits. Use at your own risk.
