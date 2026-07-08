# glucoseImporter 배포 자동화 (fastlane)

App Store 배포를 fastlane으로 자동화한 설정 문서입니다.
소스만 수정하면 **명령어 하나**로 빌드 → 업로드 → 심사 제출까지 처리됩니다.

- 작성일: 2026-07-08
- 앱: `com.bnz.glucoseImporter` / 팀: `6N5396RU93`
- fastlane 버전: 2.237.0 (Homebrew 설치)

---

## 1. 평소 배포 방법 (매번 이 3단계)

### 1단계. 소스 수정
Xcode에서 기능 개선/버그 수정 진행.

### 2단계. 이번 버전 변경사항(릴리즈노트) 작성
아래 두 파일만 편집하면 됩니다. (앱스토어 웹사이트 입력 대체)
- `fastlane/metadata/ko/release_notes.txt`
- `fastlane/metadata/en-US/release_notes.txt`

### 3단계. 배포 명령 실행
```bash
cd /Users/sjo/xcode/glucoseImporter
fastlane release version:1.1
```

`version:` 에는 **새 버전 번호**를 지정합니다. (현재 라이브가 1.0이므로 같은 번호는 불가)
- 버그 수정: `1.0.1`
- 기능 추가: `1.1`

실행하면 자동으로 처리되는 것:
1. 빌드번호 자동 증가 (App Store Connect 최신 번호 +1, 충돌 없음)
2. 아카이브 + 코드 서명 (자동 서명)
3. App Store Connect 업로드
4. 릴리즈노트 등 메타데이터 반영
5. 암호화 수출규정 / IDFA 사용여부 질문 자동 응답
6. 심사 제출
7. 승인되면 자동 출시

---

## 2. 명령어 종류

| 명령 | 동작 |
|------|------|
| `fastlane build` | 로컬 빌드만 (업로드 X). 소스에 문제없는지 확인용. API 키 불필요 |
| `fastlane upload version:1.1` | 빌드 + 업로드 (심사 제출 X). 웹에서 직접 제출하고 싶을 때 |
| `fastlane release version:1.1` | **전자동** — 업로드 + 심사 제출 |

`version` 을 생략하면 실행 중에 물어봅니다.

---

## 3. 파일 구조

```
fastlane/
├── Appfile              # 앱 Bundle ID, 팀 ID (비밀 아님)
├── Fastfile             # 배포 lane 정의 (build / upload / release)
├── .env                 # API 키 ID들 (⚠️ git 제외, 커밋 금지)
├── .env.example         # .env 작성 예시 (커밋됨)
├── AuthKey.p8           # App Store Connect API 키 (⚠️ git 제외, 커밋 금지)
└── metadata/            # 앱스토어 메타데이터 (릴리즈노트 등)
    ├── ko/release_notes.txt
    └── en-US/release_notes.txt
```

메타데이터는 `fastlane deliver download_metadata` 로 앱스토어의 현재 값을 내려받아 세팅되어 있습니다.
릴리즈노트 외 다른 항목(설명/키워드 등)을 바꾸려면 해당 `.txt` 파일을 수정 후 배포하면 반영됩니다.

---

## 4. 인증 (App Store Connect API 키)

- Apple ID 2단계 인증(2FA) 없이 완전 무인 자동화하기 위해 API 키를 사용합니다.
- 키 정보:
  - **Key ID**: `KKYQU3Q99F` (실제 값은 `fastlane/.env` 참고)
  - **Issuer ID**: `fastlane/.env` 참고
  - **`.p8` 파일**: `fastlane/AuthKey.p8`
- `.env` 와 `AuthKey.p8` 는 `.gitignore` 로 커밋에서 제외됩니다. **절대 커밋하지 마세요.**

### 새 컴퓨터에서 셋업하려면
1. `brew install fastlane`
2. App Store Connect에서 API 키(.p8) 발급 → `fastlane/AuthKey.p8` 로 저장
3. `cp fastlane/.env.example fastlane/.env` 후 Key ID / Issuer ID 입력

---

## 5. 자동 응답 설정 (앱스토어 웹 입력 대체)

Fastfile에서 아래 항목을 코드로 자동 처리합니다. 웹사이트에서 매번 묻던 것들입니다.

- **암호화 수출규정**: `ITSAppUsesNonExemptEncryption=NO` (표준 HTTPS만 사용 → 비해당)
  - ⚠️ 만약 커스텀 암호화를 추가하면 Fastfile의 이 설정을 제거해야 합니다.
- **광고 식별자(IDFA)**: 미사용으로 응답 (`add_id_info_uses_idfa: false`)
- **승인 후 출시**: 자동 출시 (`automatic_release: true`)
  - 수동으로 출시 버튼을 누르고 싶으면 Fastfile에서 `false` 로 변경.

---

## 6. 참고 / 트러블슈팅

- **빌드번호 방식**: 로컬에 저장하지 않고 App Store Connect의 최신 빌드번호를 조회해 +1 합니다. 여러 기기에서 배포해도 충돌하지 않습니다.
- **버전번호 방식**: 프로젝트 파일(`project.pbxproj`)을 수정하지 않고, 빌드 시점에 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 을 주입합니다. 따라서 배포해도 git에 변경사항이 생기지 않습니다.
- **로케일 경고**: fastlane은 UTF-8 로케일이 필요합니다. `fastlane/.env` 에 `LANG` / `LC_ALL` 을 설정해 두었습니다.
- **로컬 빌드 산출물**: `build/` 폴더에 `.ipa` 가 생성되며 `.gitignore` 에 의해 커밋에서 제외됩니다.
- **첫 실제 배포**는 로그를 보며 진행하는 것을 권장합니다.
