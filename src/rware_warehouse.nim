## The rware-warehouse game server entrypoint.
##
## SEED RANDOMISATION HAPPENS HERE, before `config.update`, so every
## seed-derived draw follows the FINAL seed (the starter's rule). Both RNG
## streams -- the reset draw (spawn cells, facings, the opening request board)
## and the request stream -- are pure functions of it, so an episode is
## reproducible from the seed the replay config records.

import std/[os, random, strutils]
import bitworld/runtime
import rware/[sim, server]

when isMainModule:
  let runtimeCfg = readRuntimeConfig()
  var config = defaultGameConfig()
  randomize()
  config.seed = rand(1 .. 2_000_000_000)
  config.update(runtimeCfg.config)
  config.clampConfig()

  let replayOut = block:
    let path = outputPathFromCogameEnv(
      CogameSaveReplayUriEnv, "rware-warehouse.replay")
    if path.len > 0: path
    else: getEnv("RWARE_REPLAY_OUT").strip()
  if replayOut.len > 0:
    let dir = replayOut.parentDir()
    if dir.len > 0:
      createDir(dir)

  runServerLoop(
    host = runtimeCfg.host,
    port = runtimeCfg.port,
    initialConfig = config,
    saveReplayPath = replayOut,
    loadReplayPath = (if runtimeCfg.replayMode:
        pathFromCogameEnv(CogameLoadReplayUriEnv) else: ""),
    runtimeConfig = runtimeCfg
  )
