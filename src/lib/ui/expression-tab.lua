--- The expression editor's live preview, driver side. lib/ui/expressions.js sends `_EVAL_EXPRESSION` with
--- `{ id, mode, expression }` as the integrator types, once the driver calls `serve()`, and gets EVAL_RESULT back:
--- `{ id, rendered, substituted, result, error, hold? }` plus the driver's own fields. Nothing is saved or watched.
---
--- `result` is text, as the page shows it, and `error` is "" when there is none. `hold` is true when the driver
--- refuses the text whatever its variables hold, so the page keeps Save back; its reason is the error, and the text
--- is not evaluated.

require("drivers-common-public.global.handlers")

local Expressions = require("lib.expressions")
local log = require("lib.logging")
local page = require("lib.ui.page")
local pageParams = require("lib.ui.page-params")

local ExpressionTab = {}

--- Every mode the engine evaluates.
local MODES = { "equation", "condition", "string" }

--- @param text string
--- @param bytes integer|nil
--- @return string cut At most that many bytes, on a whole character: a UTF-8 lead byte left on its own isn't text.
local function cut(text, bytes)
  if not bytes or #text <= bytes then
    return text
  end
  return (text:sub(1, bytes):gsub("[\192-\255][\128-\191]*$", ""))
end

--- @class ExpressionTabOptions
--- @field modes? string[] The modes the page may ask for; the first answers any other. Default equation, condition, string.
--- @field maxLength? integer The longest expression evaluated, in bytes. The rest is cut, and `substituted` too.
--- @field hold? fun(expression: string, mode: string): string|nil Why the driver refuses this text whatever its variables hold.
--- @field extra? fun(evaluation: ExpressionEvaluation, mode: string, expression: string): table|nil Fields to add.
--- @field wrap? fun(handler: function): function Wraps the handler, as a license gate does.

--- Evaluates one preview and answers it.
--- @param options ExpressionTabOptions
--- @param params table
--- @return table answer What EVAL_RESULT carries.
local function answer(options, params)
  local modes = options.modes or MODES
  local mode = modes[1]
  for _, known in ipairs(modes) do
    if params.mode == known then
      mode = known
    end
  end
  local expression = cut(tostring(params.expression or ""), options.maxLength)
  local held = options.hold and options.hold(expression, mode) or nil
  -- A held text isn't evaluated: what it would give doesn't matter while it can't be saved.
  local evaluation = held and { rendered = Expressions.render(expression, mode) }
    or Expressions.evaluate(mode, expression)
  local reply = {
    id = tostring(params.id or ""),
    rendered = evaluation.rendered or "",
    substituted = cut(evaluation.substituted or "", options.maxLength),
    result = evaluation.result ~= nil and tostring(evaluation.result) or "",
    error = held and tostring(held) or evaluation.error or "",
    hold = held and true or nil,
  }
  if options.extra then
    -- The kit's own fields win: the page routes the answer by its id.
    for key, value in pairs(options.extra(evaluation, mode, expression) or {}) do
      if reply[key] == nil then
        reply[key] = value
      end
    end
  end
  return reply
end

--- Answers the expression editor's preview. Call it once, as the driver loads.
--- @param options? ExpressionTabOptions
function ExpressionTab.serve(options)
  options = options or {}
  local function handler(tParams)
    log:trace("UIR._EVAL_EXPRESSION()")
    page.send("EVAL_RESULT", answer(options, pageParams(tParams)))
  end
  UIR._EVAL_EXPRESSION = options.wrap and options.wrap(handler) or handler
end

return ExpressionTab
