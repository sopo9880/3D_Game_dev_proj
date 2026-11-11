extends Node
## 오토로드. 시작 시 콘텐츠를 읽고, 오류가 있으면 실행을 중단한다.

const DATA_DIR := "res://data"

var db: ContentDB


func _ready() -> void:
	db = ContentDB.load_from_dir(DATA_DIR)
	if not db.is_valid():
		for e in db.errors:
			push_error("[Registry] %s" % e)
		OS.alert("콘텐츠 데이터 오류:\n" + "\n".join(db.errors), "Edenfall")
		get_tree().quit(1)
