## Frozen numeric policy over the ordinary RWARE seat observation.

import std/[json, os]
import curly
import policy_actions

proc chooseNumericOrder*(request: JsonNode, session: string): JsonNode =
  let endpoint = getEnv("PLAYER_NUMERIC_URL")
  doAssert endpoint.len > 0
  let choices = actionChoices(request["observation"])
  var mask = newJArray()
  for choice in choices: mask.add(%(choice.kind != JNull))
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  let key = getEnv("PLAYER_NUMERIC_KEY")
  if key.len > 0: headers["authorization"] = "Bearer " & key
  let body = %*{"session": session, "seat": request["seat"],
    "decision_id": request["turn"],
    "values": values(request["observation"]), "action_mask": mask}
  let response = newCurly().post(endpoint, headers, $body,
    max(1, (request["deadline_ms"].getInt() - 1000) div 1000))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "numeric policy HTTP " & $response.code)
  let actions = parseJson(response.body)["actions"]
  if actions.len != 1:
    raise newException(ValueError, "numeric policy returned wrong action count")
  let index = actions[0].getInt()
  if index < 0 or index >= ActionCount or choices[index].kind == JNull:
    raise newException(ValueError, "numeric policy returned illegal order")
  choices[index]
