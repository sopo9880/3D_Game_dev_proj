# Edenfall

Godot 4.7.2로 만드는 3D 협동 게임. **가꾸고(힐링) · 자동화하고(공장) · 싸워서(FPS) · 세계를 복원한다.**
1~8인 협동 PvE(싱글 플레이 가능), Steam(Windows 우선) 출시 목표.

현재 버전 **0.1.1** — M0(위험 검증) 진행 중.

| 되어 있는 것 | 상태 |
| --- | --- |
| 설계 문서 (Blueprint v0.3) | 완료 |
| 공장 시뮬레이션 코어: 벨트, 채굴·제련·조립, 분배/합류, 저장, 발전·전력망, 저장/불러오기 | 단위 테스트 20개 통과 |
| 사격 감각 테스트용 사격장: 이동, 무기 3종, 수치 조정 패널, 협동/전술 아레나 규칙 전환(F2) | 첫 버전, 사람의 평가 필요 |
| 푸시마다 테스트 + Windows 빌드 자동 생성 | 설정 완료 |
| 멀티플레이 뼈대, 건축 모드, 적 AI, 농사, 복원 | 아직 없음 |

## 테스트 빌드 받기

저장소의 **Releases → `dev-latest`** 에서 zip을 받아 풀고 `Edenfall.exe`를 실행한다.
조작법과 의견 주는 법은 [Blueprint/08_dev_process.md](Blueprint/08_dev_process.md#테스트-빌드).

## 직접 실행

Godot 4.7.2(표준판)로 이 폴더를 열고 F5. 테스트는:

```bash
godot --headless --import
```

```bash
godot --headless -s tests/run_tests.gd
```

## 문서

모든 설계는 [`Blueprint/`](Blueprint/README.md)에 있다.

1. [Blueprint 개요와 변경점](Blueprint/README.md)
2. [비전과 핵심 루프](Blueprint/01_vision.md)
3. [버티컬 슬라이스 명세](Blueprint/05_vertical_slice.md)
4. [로드맵과 현재 진행 상황](Blueprint/06_roadmap.md)
5. [버전 규칙과 테스트 빌드](Blueprint/08_dev_process.md)
