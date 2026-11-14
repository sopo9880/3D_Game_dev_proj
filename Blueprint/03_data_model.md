# 03. 데이터 모델

콘텐츠(아이템, 레시피, 구조물)는 코드가 아니라 **데이터**로 정의한다. 새 아이템을 추가할 때 스크립트를 고치지 않는 것이 목표다.

## 식별자

| 대상 | 형식 | 예 | 비고 |
| --- | --- | --- | --- |
| 콘텐츠 정의 | 소문자 스네이크 문자열 | `iron_ingot`, `smelter` | 세이브에 문자열로 저장. **한번 배포한 ID는 바꾸지 않는다** |
| 구조물 인스턴스 | 64비트 정수 | `10482` | 호스트가 1부터 순서대로 발급. 재사용하지 않는다 |
| 플레이어 | 문자열 | Steam ID / 개발 중에는 `dev_1` | 세이브의 키 |
| 구역 | 소문자 스네이크 문자열 | `garden`, `blighted_hollow` | |

시뮬레이션 내부에서는 속도를 위해 문자열 ID를 로딩 시점에 정수 인덱스로 바꿔 쓴다. 이 인덱스는 저장하지 않는다.

## 콘텐츠 정의 (JSON)

`res://data/` 아래 JSON 파일(`items.json`, `recipes.json`, `structures.json`, `weapons.json`, `zones.json`, `enemies.json`, `map_slice.json` 등). 구역은 `zones.json`에 규칙(선행 구역, 캡슐, 비콘 자리, 보상)이, `map_slice.json`의 `zones` 목록에 지형과 전투 배치(범위, 입구, 출현 지점과 적 종류, 우두머리)가 있다. 시작 시 읽어서 아래의 정의 객체(`RefCounted`)로 만든다. `.tres` 대신 JSON을 쓰는 이유는 [D-026](07_decisions.md) 참고. 아래 표는 정의 객체의 필드다(JSON의 키 이름은 `data/`의 실제 파일이 기준).

### ItemDef

| 필드 | 형 | 설명 |
| --- | --- | --- |
| `id` | StringName | |
| `display_name` | String | 번역 키 |
| `icon` | Texture2D | |
| `stack_size` | int | 인벤토리 한 칸 최대 수량 |
| `category` | enum | `RAW, MATERIAL, PART, CROP, SEED, AMMO, CONSUMABLE, KEY` |
| `belt_mesh` | Mesh | 벨트 위에 그릴 모양(MultiMesh용) |

### RecipeDef

| 필드 | 형 | 설명 |
| --- | --- | --- |
| `id` | StringName | |
| `inputs` | Array[ItemStack] | 아이템 ID와 수량 |
| `outputs` | Array[ItemStack] | |
| `craft_ticks` | int | 제작 시간. 10틱 = 1초 |
| `machine` | StringName | 어느 설비에서 가능한지(`workbench` 포함) |
| `unlocked_by_default` | bool | false면 연구/설계도로 해금 |

시간과 수량은 전부 정수다. "분당 30개"는 `craft_ticks = 20, 출력 1개`로 표현한다.

### StructureDef

| 필드 | 형 | 설명 |
| --- | --- | --- |
| `id` | StringName | |
| `tab` | enum | `BUILDING, INDUSTRY, NATURE, INTERIOR` |
| `placement` | enum | `GRID, FREE` |
| `footprint` | Vector3i | 점유 칸(GRID일 때) |
| `cost` | Array[ItemStack] | 설치 비용. 철거 시 전액 환급 |
| `scene` | PackedScene | 보이는 모습 |
| `sim_kind` | enum | `NONE, MINER, CRAFTER, BELT, JUNCTION, STORAGE, GENERATOR, PLOT, BEACON, POWER_POLE` |
| `ports` | Array[PortDef] | 로컬 칸 좌표, 방향, 입력/출력 |
| `power_use` | int | 가동 시 전력 수요 |
| `power_gen` | int | 발전량 |
| `power_radius` | int | 전력 범위(칸) |
| `params` | Dictionary | 종류별 값(벨트 속도, 저장 칸 수 등) |

### WeaponDef, EnemyDef, CropDef, ZoneDef

같은 방식. 필드는 [05](05_vertical_slice.md)의 수치 표가 곧 필드 목록이다.

### 레지스트리

`ContentDB`(순수 클래스)가 `res://data/`를 읽어 ID → 정의 사전을 만들고, `Registry` 오토로드가 그것을 하나 들고 있다. 시뮬레이션은 오토로드가 아니라 `ContentDB`를 직접 받는다. ID 중복, 없는 아이템을 참조하는 레시피 등은 **시작 시점에 오류로 중단**한다(헤드리스 테스트에서도 같은 검사를 돌린다).

## 런타임 상태

### 구조물 인스턴스

```
StructureState
  id: int                # 인스턴스 ID
  def_id: StringName
  cell: Vector3i         # GRID: 원점 칸
  rot: int               # 0..3
  xform: Transform3D     # FREE일 때만
  placed_by: String      # 플레이어 ID
  sim: Dictionary        # sim_kind별 상태 (레시피, 버퍼, 진행 틱 등)
```

### 청크

구조물은 **32×32칸 수평 청크**(높이는 무제한)에 속한다. 청크는 지금은 조회·복제·저장의 단위일 뿐이고, 나중에 맵 스트리밍의 단위가 된다.

- `chunk_key = (floor(x / 32), floor(z / 32))`
- 칸 점유는 `Dictionary[Vector3i, int]` (칸 → 구조물 ID). 청크별로 나눠 보관.

### 플레이어

```
PlayerState
  id: String
  display_name: String
  role: OWNER | BUILDER | VISITOR
  pos, yaw: 마지막 위치
  health: int
  inventory: Array[ItemStack]   # 고정 칸 수
  weapons: Array[WeaponState]   # def_id, 장착 개조, 탄약
```

### 월드

```
WorldState
  save_version: int
  world_id: String (UUID)
  name: String
  tick: int                     # 누적 시뮬레이션 틱
  next_structure_id: int
  zones: { zone_id: progress(0..100), beacon_built: bool }
  unlocked_recipes: Array[StringName]
  structures: 청크별 StructureState 목록
  belt_lines: 벨트 라인별 슬롯 배열
  players: { player_id: PlayerState }
  host_roles: { player_id: role }
```

## 저장

### 위치와 구조 (구현됨)

```
user://worlds/
  <world_id>/
    manifest.json        # save_version, 이름, 게임 버전, 저장 시각, 플레이 틱
    world.bin            # 압축한 월드 데이터: 시뮬레이션 상태 전체 + 플레이어별 마지막 위치
  <world_id>.tmp/        # 쓰는 중인 새 저장
  <world_id>.backups/
    <시각>/              # 이전 저장들. 최근 5개
```

- `manifest.json`은 사람이 읽을 수 있는 JSON이고 시작 화면의 월드 목록이 이것만 읽는다.
- `world.bin`은 기본형만 담은 사전을 `var_to_bytes`로 직렬화해 zstd로 압축한 것이다. 플레이어 소지품은 시뮬레이션 상태의 일부라 여기에 함께 들어 있다(D-013).
- **객체 직렬화는 쓰지 않는다**(`bytes_to_var`만, `_with_objects` 금지). 남이 준 세이브 파일이 코드를 실행할 길을 만들지 않기 위해서다.
- 청크별 파일 분할과 계정 단위 파일(`account.json`)은 아직 없다. 월드가 커져 저장 시간이 문제가 되면 나눈다.

### 안전한 쓰기 (구현됨)

1. `<id>.tmp/`에 전부 쓴다.
2. 방금 쓴 manifest와 world.bin을 다시 읽어 풀리는지 확인한다.
3. 기존 `<id>/`를 `<id>.backups/<시각>/`으로 옮기고, `<id>.tmp/`를 `<id>/`로 이름을 바꾼다.
4. 백업은 최근 5개만 남긴다.

어느 순간에 꺼져도 다음 실행 때 복구한다.

| 꺼진 시점 | 남은 상태 | 복구 |
| --- | --- | --- |
| 1~2 도중 | 본 저장 온전 + 쓰다 만 임시 | 임시를 버린다 |
| 3의 두 이름 바꾸기 사이 | 본 저장 없음 + 온전한 임시 | 임시를 본 저장으로 올린다 |
| 본 저장이 깨짐 | 백업들 | 가장 최근 백업을 불러오고 그 사실을 알린다 |

### 두 가지 버전 번호

- `save_version`(manifest): **파일 구성**의 버전. 지금 1. 게임이 아는 것보다 높으면 열지 않고 안내한다.
- `format`(월드 데이터 안): **시뮬레이션 상태**의 형식. 지금 5. 낮으면 `SaveMigrations`가 한 단계씩 올린다.

형식이 바뀔 때마다 그 전 형식의 샘플을 `tests/fixtures/`에 남기고, 불러와서 계속 돌아가는지를 테스트한다. 지금은 형식 1(소지품이 없던 v0.2.x), 형식 2(건축 구역이 없던 v0.3.0), 형식 3(구역 복원이 없던 v0.3.x), 형식 4(연구가 없던 v0.5.1) 샘플이 있다.

### 저장 시점 (구현됨)

- 자동 저장 5분마다
- 호스트가 나갈 때(F10, 창 닫기), 수동 저장(F6)
- 저장은 틱 사이에 상태를 복사한 뒤 **별도 스레드**에서 직렬화·압축·쓰기를 한다. 종료 직전에만 끝날 때까지 기다린다.
- 플레이어가 접속을 끊으면 그 사람의 마지막 위치를 기억해 두었다가 다음 저장에 넣고, 다시 들어오면 그 자리에서 시작한다.

### 버전 관리

- `save_version`은 정수. 포맷이 바뀔 때마다 1 올린다.
- `migrations/` 에 `v3_to_v4(dict) -> dict` 같은 순수 함수를 둔다. 불러올 때 현재 버전까지 차례로 적용한다.
- 마이그레이션마다 **이전 버전 샘플 세이브를 테스트 자산으로 보관**하고 CI에서 불러오기를 검증한다.
- 게임 버전보다 높은 `save_version`은 불러오지 않고 안내한다.
- 알 수 없는 콘텐츠 ID(삭제된 아이템 등)는 버리지 않고 `unknown` 자리표시자로 유지해 재저장해도 손실이 없게 한다.
