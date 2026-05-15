# watchCat 설치

## Homebrew Cask로 설치

```bash
brew tap hyunjoon0312/watchcat
brew install --cask watchcat
```

처음 실행 시 macOS Gatekeeper 경고가 뜹니다(서명되지 않은 앱이므로). 다음 중 하나로 허용해주세요.

### 방법 1: Finder에서 우클릭 → 열기
1. `/Applications/watchCat.app`를 Finder에서 찾기
2. 마우스 우클릭 → "열기"
3. 다이얼로그가 뜨면 "열기" 클릭

### 방법 2: 명령어로 quarantine 속성 제거
```bash
xattr -dr com.apple.quarantine /Applications/watchCat.app
```

이후엔 일반 앱처럼 그냥 실행하면 됩니다.

## 제거

```bash
brew uninstall --cask watchcat
```

사용자 데이터(SQLite DB, 설정)까지 삭제하려면:

```bash
brew uninstall --zap --cask watchcat
```

---

## 새 버전 릴리스 절차 (개발자용)

1. 변경사항 커밋 후 `project.yml`의 `MARKETING_VERSION` 갱신
2. Release 빌드:
   ```bash
   xcodebuild -project watchCat.xcodeproj -scheme watchCat \
     -configuration Release -derivedDataPath build-release -quiet
   ```
3. zip + 해시:
   ```bash
   cd build-release/Build/Products/Release
   ditto -c -k --keepParent watchCat.app /tmp/watchCat-<version>.zip
   shasum -a 256 /tmp/watchCat-<version>.zip
   ```
4. 태그 + 푸쉬:
   ```bash
   git tag v<version> && git push origin v<version>
   ```
5. GitHub Release 페이지에서 zip 업로드 + 릴리스 노트 작성
6. `homebrew-watchcat` tap 저장소의 `Casks/watchcat.rb`에서 `version`/`sha256` 갱신 후 푸쉬
