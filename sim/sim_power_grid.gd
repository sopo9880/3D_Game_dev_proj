class_name SimPowerGrid
extends RefCounted
## 전력망 하나. 매 틱 수요와 공급을 다시 집계한다.

var demand: int = 0
var supply: int = 0
var ratio: int = 0  ## 충족률 천분율 (0..1000)
