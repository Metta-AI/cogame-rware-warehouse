version       = "0.1.0"
author        = "Softmax"
description   = "RWARE as a Coworld: four robot drivers, one cooperative warehouse"
license       = "MIT"
srcDir        = "src"
bin           = @["rware_warehouse", "rware_warehouse_player"]

requires "nim >= 2.2.4"
requires "mummy"
requires "curly"
requires "whisky"
requires "jsony"
requires "bitworld"
