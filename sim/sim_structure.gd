class_name SimStructure
extends RefCounted
## 설치된 구조물 하나의 상태. 종류별 필드를 한 클래스에 모아 둔다
## (틱 루프에서 캐스팅과 가상 호출을 피하기 위해서다).

enum State { IDLE, RUNNING, NO_INPUT, OUTPUT_BLOCKED, NO_POWER, NO_RECIPE }

var id: int
var def: StructureDef
var kind: int
var cell: Vector3i
var rot: int = 0
var placed_by: String = ""

# --- 토폴로지 캐시 (저장하지 않는다) ---
var grid: SimPowerGrid = null
var out_lines: Array[SimStructure] = []

# --- 제작 기계 (채굴기, 제련기, 조립기) ---
var recipe: RecipeDef = null
var working: bool = false
var progress: int = 0            ## 천분율 누적. recipe.ticks * 1000 이면 완료
var in_counts: PackedInt32Array = []
var out_count: int = 0
var state: int = State.IDLE
var produced_total: int = 0

# --- 발전기 ---
var fuel_item: int = -1
var fuel_count: int = 0
var burn_left: int = 0

# --- 저장소: 아이템 인덱스 → 수량 (넣은 순서 유지) ---
var store: Dictionary[int, int] = {}
var store_slots_used: int = 0

# --- 분배/합류기 ---
var j_item: int = 0              ## 0 = 비어 있음, 그 외 = 아이템 인덱스 + 1
var rr: int = 0

# --- 벨트: slots[0]이 하류 끝(머리), slots[n-1]이 상류 끝(꼬리) ---
var cells: Array[Vector3i] = []
var dir_in: int = 0
var dir_out: int = 0
var period: int = 5
var slots: PackedInt32Array = []  ## 0 = 비어 있음, 그 외 = 아이템 인덱스 + 1
var item_count: int = 0
var packed: int = 0               ## 머리부터 연속으로 차 있는 칸 수의 하한(캐시)
var dst: SimStructure = null
var passed_total: int = 0

# --- 밭 ---
var crop: int = -1               ## 작물 인덱스. -1 = 비어 있음
var growth: int = 0              ## 성장 틱. 작물의 grow_ticks 이상이면 수확 가능
var watered: bool = false        ## 물을 주면 다음 성장 단계까지 두 배로 자란다

# --- 장식(자유 배치): 위치는 밀리미터, 방향은 도. 정수로 저장해 모든 피어에서 같게 한다 ---
var free_pos: Vector3i = Vector3i.ZERO
var free_yaw: int = 0
