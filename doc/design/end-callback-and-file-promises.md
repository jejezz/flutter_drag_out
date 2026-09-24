# 설계: 종료 콜백과 파일 프로미스 API

- 상태: 0.4.0 구현 중 (2026-09-24)
- 대상 버전: 0.4.0 ~ 0.6.0
- 사용처: dove-zip(압축 항목 끌어내기), daylight-commander(원격 항목 끌어내기)

## 1. 배경

지금 플러그인은 **이미 디스크에 있는 로컬 경로**만 끌어낼 수 있고, 세션이
끝났다는 사실은 `inProgress`가 `false`로 바뀌는 것으로만 알 수 있다.
두 사용처에서 다음 문제가 생긴다.

| 사용처 | 끌어내고 싶은 것 | 지금 막히는 이유 |
|---|---|---|
| dove-zip | 압축파일 안의 항목 | 디스크 경로가 없다. 미리 풀면 큰 파일·폴더는 창을 벗어나기 전에 끝나지 않는다 |
| daylight-commander | FTP/SFTP/WebDAV 항목 | 디스크 경로가 없다. 지금은 `paths`가 `null`을 돌려 앱 안 드래그로 남긴다 |

또 미리 만든 임시 파일을 언제 지워도 되는지 알 수 없다. 네이티브는 이미
드롭 여부(`dropped`)를 보내고 있지만 Dart 쪽이 버린다.

## 2. 목표 / 비목표

**목표**

1. **종료 콜백**: 세션마다 한 번, 드롭됐는지 여부와 함께 호출된다.
2. **파일 프로미스**: 이름만 먼저 넘기고, 실제 파일은 드롭된 뒤 앱이
   만든다. 대상 폴더를 알 수 있는 플랫폼(macOS)에서는 그 자리에 바로 쓴다.
3. **하위 호환**: 기존 호출 코드(daylight-commander)는 수정 없이 동작한다.

**비목표**

- 진행률 표시: 쓰기는 앱 코드가 하므로 진행률 UI도 앱이 맡는다.
- 이동(move) 지원: 지금처럼 복사만 허용한다.
- 끌어들이기(drop target): 지금처럼 다른 패키지(`desktop_drop` 등)의 몫이다.

## 3. 하위 호환 원칙

daylight-commander는 다음 두 가지만 쓴다.

```dart
FlutterDragOut.maybeStartOnExit(pos, viewSize: size, paths: () => ...);
if (FlutterDragOut.inProgress) return; // 되돌아온 드롭 무시
```

1. `maybeStartOnExit`의 `paths:`, `start(List<String>) → Future<bool>`,
   `inProgress`, `isSupported`는 **시그니처와 의미를 그대로 둔다**. 새 기능은
   선택 파라미터와 새 멤버로만 추가한다.
2. `inProgress`는 지금처럼 **OS 드래그 세션이 끝나는 순간** `false`가 된다.
   프로미스 쓰기가 끝날 때까지 기다리지 않는다.
3. **경로 항목만 있는 세션은 네이티브 동작이 바뀌지 않는다.** Windows의
   "버튼을 놓은 뒤 쓰기를 기다리는" 흐름(6.2절)은 프로미스 항목이 있을 때만
   켠다.
4. 채널 프로토콜(5절)은 바뀌지만, Dart와 네이티브 코드가 같은 패키지
   버전 안에서 함께 바뀌므로 앱에는 드러나지 않는다.
5. 기존 태그(`v0.1.0` ~ `v0.3.0`)는 옮기지 않는다. git 의존성을 태그로
   고정한 앱은 `ref`를 올리기 전까지 영향이 없다.
6. 기존 `test/flutter_drag_out_test.dart`의 **동작 테스트는 수정하지 않고**
   통과해야 한다. 채널에 무엇을 보내는지 직접 확인하는 단언(`startDrag`
   인자 형식)만 4항에 따라 새 형식으로 고친다.

## 4. Dart API

### 4.1 항목

```dart
/// 끌어낼 항목 하나.
sealed class DragOutItem {
  /// 이미 디스크에 있는 파일/폴더(절대 경로).
  const factory DragOutItem.path(String path) = DragOutPath;

  /// 드롭된 뒤에 [write]가 만드는 파일/폴더.
  ///
  /// [name]은 대상에 생길 이름(경로 구분자 없음), [isDirectory]는 폴더 여부.
  const factory DragOutItem.promise({
    required String name,
    bool isDirectory,
    required Future<void> Function(DragOutWriteRequest request) write,
  }) = DragOutPromise;
}

/// 프로미스 하나를 채워 달라는 요청.
final class DragOutWriteRequest {
  /// 이 경로에 [DragOutPromise.name] 파일(또는 폴더)을 만든다.
  /// 경로의 부모 폴더는 이미 있다.
  final String targetPath;

  /// `true`면 [targetPath]가 사용자가 떨군 최종 위치다(macOS).
  /// `false`면 플러그인의 임시 폴더이고, OS가 나중에 최종 위치로 복사한다
  /// (Windows). 앱은 충돌 처리 UI를 최종 위치일 때만 띄우는 식으로 쓴다.
  final bool isFinalDestination;

  /// 사용자가 Esc로 취소했으면 `true`. 긴 쓰기는 중간중간 확인하고
  /// 멈춘다(예외를 던지면 된다).
  bool get isCancelled;
}
```

`write`가 예외를 던지면 그 항목은 실패로 처리한다(6절에서 플랫폼별 처리).

### 4.2 세션 종료

```dart
/// 세션이 끝났을 때 한 번 전달된다.
final class DragOutEnd {
  /// 다른 앱이 드롭을 받아들였으면 `true`. Esc, 받아 주는 곳이 없는 위치,
  /// 이 앱 창으로 되돌아온 드롭이면 `false`.
  final bool dropped;
}
```

**중요:** `onEnded`는 **대상 앱이 파일을 다 읽었다는 뜻이 아니다.** Finder와
Explorer는 드롭을 받은 뒤 비동기로 복사할 수 있다. `onEnded`에서 곧바로 임시
파일을 지우면 복사가 깨질 수 있다. 임시 파일은 다음 세션이나 앱 종료 때
정리하는 것을 권장한다(README에도 적는다).

### 4.3 진입점

```dart
abstract final class FlutterDragOut {
  // --- 그대로 ---
  static bool get isSupported;
  static bool get inProgress;
  static Future<bool> start(List<String> paths);

  // --- 추가 ---
  /// 이 플랫폼이 [DragOutItem.promise]를 지원하는지.
  /// `false`면 프로미스가 섞인 [startItems]는 `false`를 돌려주므로,
  /// 앱은 미리 풀어 둔 경로로 되돌아가야 한다.
  static bool get supportsPromises;

  /// [items]로 세션을 시작한다. 시작되면 `true`를 돌려주며, 그때만
  /// [onEnded]가 정확히 한 번 호출된다.
  static Future<bool> startItems(
    List<DragOutItem> items, {
    void Function(DragOutEnd end)? onEnded,
  });

  /// [paths]와 [items] 중 정확히 하나를 준다(assert).
  /// [paths]는 `items: () => paths()?.map(DragOutItem.path).toList()`와 같다.
  static void maybeStartOnExit(
    Offset globalPosition, {
    required Size viewSize,
    List<String>? Function()? paths,       // 기존: required → optional
    List<DragOutItem>? Function()? items,  // 추가
    void Function(DragOutEnd end)? onEnded, // 추가
  });
}
```

`paths:`를 required에서 optional로 바꾸는 것은 기존 호출부를 깨지 않는다.

기존 `start(paths)`는 `startItems(paths.map(DragOutItem.path).toList())`로
구현한다.

### 4.4 호출 순서

- `startItems`가 `true`를 돌려준 세션에 대해:
  1. (0회 이상) `write` 호출. 시점은 플랫폼에 따라 다르다(6절).
  2. `inProgress = false` → `onEnded(DragOutEnd)` 순서로 정확히 한 번.
- macOS에서는 **2가 1보다 먼저** 올 수 있다(드롭 직후 세션이 끝나고, Finder가
  그 뒤에 쓰기를 요청한다). Windows에서는 1이 모두 끝난 뒤 2가 온다.
- 드롭이 안 되면 `write`는 한 번도 호출되지 않는다.

## 5. 채널 프로토콜 (`flutter_drag_out`)

세션 ID는 Dart가 정한다(증가하는 정수). 네이티브가 ID를 돌려줄 필요가 없고,
늦게 도착한 메시지를 세션별로 걸러 내기 쉽다.

| 방향 | 메서드 | 인자 | 응답 |
|---|---|---|---|
| Dart → 네이티브 | `startDrag` | `{session: int, items: [{type: 'path', path}, {type: 'promise', id: int, name, directory: bool}]}` | `bool` |
| 네이티브 → Dart | `dragEnded` | `{session, dropped: bool}` | 없음 |
| 네이티브 → Dart | `writePromise` | `{session, id, targetPath, final: bool}` | 성공 시 `null`, 실패 시 `PlatformException` |
| 네이티브 → Dart | `cancelPromises` | `{session}` | 없음 |

- `startDrag`는 과거 형식(`List<String>`)도 받아들인다. 네이티브 코드를
  단계별로 옮기는 동안 편하고, 비용이 거의 없다.
- Dart 쪽 `dragEnded` 처리기는 과거 형식(bare `bool`)도 받아들인다.
- Dart는 세션별로 `{onEnded, promises by id, cancelled}`를 보관한다.
  `dropped == false`로 끝났거나 모든 프로미스를 한 번씩 썼으면 지운다.

## 6. 플랫폼별 구현

### 6.1 macOS — `NSFilePromiseProvider` (0.5.0)

- 경로 항목: 지금처럼 `NSURL(fileURLWithPath:)`.
- 프로미스 항목: `NSFilePromiseProvider(fileType:delegate:)`, `userInfo`에
  `(session, id)`를 넣는다. 한 세션에 두 종류를 섞을 수 있다.
  - `fileType`: 폴더면 `public.folder`, 파일이면 확장자로 찾은 UTI, 못
    찾으면 `public.data`. 최소 지원이 10.15이므로 `UTType`(11+) 대신
    `UTTypeCreatePreferredIdentifierForTag`를 쓰거나 가용성 분기를 둔다.
  - `fileNameForType` → `name`.
  - `writePromiseTo url:completionHandler:` → 메인 스레드에서 `writePromise`
    (`targetPath: url.path, final: true`)를 호출하고, 응답이 오면
    `completionHandler(nil 또는 NSError)`. 델리게이트 메서드는 바로 반환하고
    완료 핸들러만 나중에 부른다.
  - `operationQueue(for:)`: 전용 `OperationQueue`를 돌려주고, 채널 호출은
    메인 큐로 넘긴다.
  - 드래그 이미지: `NSWorkspace.shared.icon(forFileType:)`.
- `sourceOperationMaskFor`, 자기 앱으로 돌아온 드롭 거부, 가짜 mouse-up은
  그대로 둔다.
- `endedAt`: `dragEnded {session, dropped: operation != []}`.
- **한계:** 파일 프로미스를 받지 않는 앱(브라우저 업로드 영역, 일부 Electron
  앱 등)에는 프로미스 항목을 떨굴 수 없다(`dropped: false`). README에 적는다.

### 6.2 Windows — 드롭 시점에 임시 폴더를 채우는 방식 (0.6.0)

Windows에는 "대상 폴더를 알려 주는" 표준 방식이 없다.
`CFSTR_FILEDESCRIPTOR` + `CFSTR_FILECONTENTS`(가상 파일)는 Explorer가 우리
`IDataObject::GetData`/`IStream::Read`를 UI 스레드에서 **동기로** 부르는데,
Dart 응답도 같은 스레드로 오므로 중첩 메시지 루프 없이는 교착된다. 폴더를
평탄화해 기술하는 일도 번거롭다. 그래서 7-Zip 파일 관리자와 같은 방식을 쓴다.

1. 시작할 때 세션 임시 폴더 `%TEMP%\flutter_drag_out\<pid>-<session>\`를
   만들고, 프로미스마다 **빈 자리표시 파일/폴더**를 만든다. `CF_HDROP`에는
   경로 항목과 자리표시 경로를 함께 넣는다.
2. `GiveFeedback(effect)`로 마지막 효과를 기억한다.
3. `QueryContinueDrag`에서 버튼이 떼어졌을 때:
   - 우리 창 위이거나 마지막 효과가 `DROPEFFECT_NONE`이면 → 지금처럼
     `DRAGDROP_S_CANCEL`(쓰기 없음).
   - 프로미스가 없으면 → 지금처럼 즉시 `DRAGDROP_S_DROP`(**동작 변화 없음**).
   - 프로미스가 있으면 → 각 프로미스에 `writePromise(final: false)`를 보내고,
     모두 끝날 때까지 `S_OK`를 돌려 드래그 루프를 유지한다. `DoDragDrop`의
     모달 루프가 메시지를 계속 처리하므로 채널 응답은 도착한다.
   - 기다리는 동안 50ms 타이머를 걸어 루프를 깨운다. 입력이 없을 때도
     `QueryContinueDrag`가 다시 불리게 하기 위해서다(6.4절 검증 항목).
   - 모두 끝나면 `DRAGDROP_S_DROP`. 실패한 항목은 `CF_HDROP`을 다시
     `SetData`해 목록에서 빼고, 남는 게 없으면 `DRAGDROP_S_CANCEL`.
   - 기다리는 중 Esc → `cancelPromises` 보내고 `DRAGDROP_S_CANCEL`.
4. `dragEnded {session, dropped}`는 `DoDragDrop`이 반환된 뒤 지금처럼 보낸다.
5. 임시 폴더 정리: Explorer가 비동기로 복사할 수 있으므로 **세션 종료 즉시
   지우지 않는다.** 플러그인을 초기화할 때와 새 세션을 시작할 때, 다른
   pid의 폴더와 이 pid의 지난 세션 폴더를 지운다.

**알려진 UX 한계:** 쓰기를 기다리는 동안 커서를 움직이면 드롭 위치가 바뀐다.
`ClipCursor`로 떼어낸 지점에 커서를 묶는 방법을 실기기에서 시험해 보고,
쓸지 정한다. 긴 쓰기에서는 앱이 자기 창에 진행률을 띄우는 것을 권장한다
(Flutter는 모달 루프 안에서도 그린다).

### 6.3 Linux (보류)

- 0.4.0에서 `dragEnded {session, dropped}`만 맞춘다(네이티브는 이미
  `dropped`를 보낸다).
- `supportsPromises == false`. 프로미스가 섞인 `startItems`는 `false`.
- 나중 후보: X11에서 XDS(`XdndDirectSave0`, Nautilus·Dolphin 지원)로 최종
  위치에 쓰기. Wayland에는 표준이 없어 Windows와 같은 임시 폴더 방식이
  필요하다. `drag-data-get`이 동기 시그널이라 중첩 메인 루프가 필요하다.

### 6.4 실기기에서 확인할 것

| # | 플랫폼 | 확인할 것 |
|---|---|---|
| 1 | macOS | 같은 이름이 이미 있을 때 Finder가 `writePromiseTo`에 어떤 URL을 주는지(자동 이름 변경인지, 덮어쓰기를 우리에게 맡기는지) |
| 2 | macOS | 폴더(`public.folder`) 프로미스가 Finder·데스크톱에서 되는지 |
| 3 | Windows | 버튼을 뗀 뒤 `S_OK`를 계속 돌려줄 때 OLE 루프가 `QueryContinueDrag`를 다시 부르는지(타이머 필요 여부) |
| 4 | Windows | 빈 자리표시 파일이 DragOver 중 Explorer의 판단(복사 가능 여부, 아이콘)에 영향을 주는지 |
| 5 | Windows | 드롭 후 Explorer가 동기로 복사하는지, 비동기로 복사하는지(임시 폴더 정리 시점 근거) |

## 7. 사용 예

### 7.1 dove-zip — 압축 목록에서 끌어내기

```dart
Draggable<ArchiveDragPayload>(
  onDragUpdate: (d) => FlutterDragOut.maybeStartOnExit(
    d.globalPosition,
    viewSize: MediaQuery.sizeOf(context),
    items: () {
      // 드래그 중에는 암호를 물을 수 없다. 모르면 앱 안 드래그로 남긴다.
      if (payload.needsPassword && password == null) return null;
      if (!FlutterDragOut.supportsPromises) return eagerTempPaths(); // 1단계 방식
      return [
        for (final e in payload.entries)
          DragOutItem.promise(
            name: e.name,
            isDirectory: e.isDirectory,
            write: (req) => extractEntryTo(
              e,
              req.targetPath,
              password: password,
              // 최종 위치일 때만 기존 충돌 대화상자를 쓴다.
              onConflict: req.isFinalDestination ? askUser : overwrite,
              isCancelled: () => req.isCancelled,
            ),
          ),
      ];
    },
  ),
  ...
)
```

dove-zip 쪽에는 "항목 하나(와 그 하위)를 **정확한 경로**에 푸는" 유스케이스가
새로 필요하다. 지금의 `ExtractEntries`는 해제 모드로 목적지를 정하는
구조이기 때문이다.

### 7.2 daylight-commander — 원격 항목 끌어내기

```dart
items: () => [
  for (final e in dragPayload.entries)
    e.location.scheme == 'file'
        ? DragOutItem.path(e.location.toFilePath())
        : DragOutItem.promise(
            name: e.name,
            isDirectory: e.isDirectory,
            write: (req) => download(e, req.targetPath),
          ),
],
```

지금 코드(`paths:`)는 그대로 두어도 되고, 원할 때 위처럼 바꾸면 된다.

## 8. 릴리스 단계

| 버전 | 내용 | 위험 |
|---|---|---|
| 0.4.0 | `DragOutItem`(경로만), `startItems`, `onEnded`, `supportsPromises`(전부 `false`), 새 채널 형식(3개 플랫폼) | 낮음. daylight-commander가 올려도 되는 첫 지점 |
| 0.5.0 | macOS 프로미스 | 중간. 6.4의 1·2 확인 |
| 0.6.0 | Windows 프로미스 | 높음. 실제 Windows 기기에서 6.4의 3~5 확인 |
| 이후 | Linux 프로미스(XDS / 임시 폴더) | 보류 |

각 버전은 새 태그로만 낸다(3절 5항).

## 9. 테스트 계획

**Dart 단위 테스트** (mock 채널)

- 기존 테스트 전부 수정 없이 통과(회귀).
- daylight-commander 패턴: 원격 항목이 섞이면 `paths`가 `null` → 시작 안 함.
- `startItems` 직렬화: 경로/프로미스 혼합, 세션 ID 증가.
- `dragEnded {session, dropped}` → 해당 세션의 `onEnded`만 호출, 순서는
  `inProgress = false`가 먼저. bare `bool` 형식도 처리.
- 시작 실패(`false`) 시 `onEnded`가 호출되지 않음.
- `writePromise` → 올바른 `write`로 라우팅, 예외는 `PlatformException` 응답.
- `cancelPromises` → `isCancelled == true`.
- 지난 세션 ID로 온 메시지는 무시.
- `supportsPromises == false`에서 프로미스가 섞이면 `startItems == false`.

**예제 앱**

- "Generated file" 프로미스(드롭 시 시각을 적은 텍스트 파일 생성),
  "Generated folder" 프로미스(파일 몇 개가 든 폴더), 느린 프로미스(5초,
  취소 확인용).
- 화면에 마지막 `onEnded` 결과 표시.

**수동 확인 목록**: macOS(Finder 창, 데스크톱, Mail 작성 창, 프로미스를
받지 않는 앱), Windows(Explorer 창, 데스크톱, 다른 드라이브, Esc 취소).

## 10. 결정이 필요한 것

1. Windows에서 쓰기를 기다리는 동안 `ClipCursor`로 커서를 묶을지(6.2).
2. 한 세션에서 일부 프로미스만 실패했을 때, 나머지만 드롭할지(현재 설계),
   전부 취소할지.
3. 프로미스 `write`에 시간 제한을 둘지. 현재 설계는 제한 없이 Esc로만
   취소한다.
