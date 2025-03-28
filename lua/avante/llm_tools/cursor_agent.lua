local Providers = require("avante.providers")
local Config = require("avante.config")
local Utils = require("avante.utils")
local Base = require("avante.llm_tools.base")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "cursor_agent"

M.get_description = function()
  return [[Este agente te permite completar tareas complejas de programación de principio a fin. Puede realizar acciones como:

  1. Modificar archivos existentes o crear nuevos archivos
  2. Ejecutar comandos en la terminal
  3. Buscar y analizar código en todo el proyecto
  4. Corregir errores automáticamente

  Para usar este agente, describe la tarea que deseas realizar en detalle. El agente planificará los pasos necesarios,
  te mostrará un plan y, con tu confirmación, ejecutará estos pasos secuencialmente.

  Este agente es ideal para:
  - Refactorizaciones complejas que afectan a múltiples archivos
  - Implementación de nuevas características
  - Corrección de errores que requieren cambios en varias partes del código
  - Tareas repetitivas que involucran múltiples comandos

  El agente siempre esperará tu confirmación antes de realizar cambios importantes en el código.]]
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "prompt",
      description = "La tarea que deseas que el agente realice",
      type = "string",
    },
    {
      name = "file_paths",
      description = "Rutas de archivos relevantes para la tarea (opcional)",
      type = "array",
      optional = true,
    },
  },
  required = { "prompt" },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "result",
    description = "El resultado del agente",
    type = "string",
  },
  {
    name = "error",
    description = "El mensaje de error si el agente falla",
    type = "string",
    optional = true,
  },
}

-- Estado del agente
local agent_state = {
  active = false,
  task = nil,
  files_context = {},
  terminal_output = {},
  current_step = 1,
  steps = {},
}

-- Obtener herramientas disponibles
local function get_available_tools()
  return {
    require("avante.llm_tools.ls"),
    require("avante.llm_tools.grep"),
    require("avante.llm_tools.glob"),
    require("avante.llm_tools.view"),
    require("avante.llm_tools.str_replace"),
    require("avante.llm_tools.write"),
    require("avante.llm_tools.bash"),
  }
end

-- Analizar pasos desde la respuesta de la IA
local function parse_steps_from_response(response)
  local steps = {}

  -- Buscar pasos numerados con un patrón simple
  for step_match in response:gmatch("(%d+)%.%s*([^\n]+)[^\n]*\n") do
    local step_number, description = step_match:match("(%d+)%.%s*([^\n]+)")
    if step_number and description then
      local step = {
        description = description,
        file_edits = {},
        terminal_commands = {},
      }

      table.insert(steps, step)
    end
  end

  -- Si no encontramos pasos con el patrón, crear un solo paso
  if #steps == 0 then
    table.insert(steps, {
      description = "Ejecutar el plan",
      file_edits = {},
      terminal_commands = {},
    })
  end

  return steps
end

-- Mostrar UI para confirmar plan
local function show_plan_ui(plan_text, on_confirm, on_cancel)
  local Popup = require("nui.popup")
  local Layout = require("nui.layout")
  local Input = require("nui.input")
  local event = require("nui.utils.autocmd").event

  -- Ventana principal del plan
  local plan_window = Popup({
    enter = true,
    focusable = true,
    border = {
      style = "rounded",
      text = {
        top = " Plan del Agente Cursor ",
        top_align = "center",
      },
    },
    position = "50%",
    size = {
      width = "80%",
      height = "60%",
    },
    buf_options = {
      modifiable = true,
      readonly = false,
    },
  })

  -- Establecer contenido
  vim.api.nvim_buf_set_lines(plan_window.bufnr, 0, -1, false, vim.split(plan_text, "\n"))
  vim.api.nvim_buf_set_option(plan_window.bufnr, "modifiable", false)

  -- Configurar keymaps
  plan_window:map("n", "y", function()
    plan_window:unmount()
    on_confirm()
  end, { noremap = true })

  plan_window:map("n", "n", function()
    plan_window:unmount()
    on_cancel()
  end, { noremap = true })

  plan_window:map("n", "q", function()
    plan_window:unmount()
    on_cancel()
  end, { noremap = true })

  -- Título en la parte inferior
  vim.api.nvim_buf_set_lines(plan_window.bufnr, -1, -1, false, {
    "",
    "Presiona 'y' para confirmar, 'n' o 'q' para cancelar"
  })

  plan_window:mount()
end

-- Función para iniciar el modo agente
local function start_agent(prompt, file_paths, on_log, on_complete)
  agent_state.task = prompt
  agent_state.active = true
  agent_state.current_step = 1
  agent_state.steps = {}
  agent_state.files_context = {}
  agent_state.terminal_output = {}

  if on_log then on_log("Iniciando agente para tarea: " .. prompt) end

  -- Recopilar contexto del proyecto
  if on_log then on_log("Recopilando contexto del proyecto...") end

  -- Obtener buffer actual
  local current_bufnr = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(current_bufnr)
  local current_content = table.concat(vim.api.nvim_buf_get_lines(current_bufnr, 0, -1, false), "\n")

  -- Añadir al contexto
  agent_state.files_context[current_file] = {
    content = current_content,
    bufnr = current_bufnr,
  }

  -- Si se proporcionaron rutas de archivos específicas, obtener su contenido
  if file_paths and #file_paths > 0 then
    for _, file_path in ipairs(file_paths) do
      if Utils.file_exists(file_path) and file_path ~= current_file then
        local content = Utils.read_file(file_path)
        if content then
          agent_state.files_context[file_path] = {
            content = content,
            bufnr = nil,
          }
        end
      end
    end
  end

  -- Planificar la tarea
  if on_log then on_log("Planificando pasos para la tarea...") end

  local Llm = require("avante.llm")

  -- Preparar contexto para el agente
  local files_info = ""
  for filename, file_data in pairs(agent_state.files_context) do
    files_info = files_info .. "\nArchivo: " .. filename .. "\n```\n" .. file_data.content .. "\n```\n"
  end

  -- Prompt para planificar
  local planning_prompt = [[
Necesito tu ayuda para planificar y ejecutar la siguiente tarea: ]] .. agent_state.task .. [[

Por favor, divídela en pasos concretos que podamos seguir. Para cada paso, proporciona:
1. Una descripción clara del paso
2. Qué archivos necesitamos modificar o crear
3. Si necesitamos ejecutar algún comando en la terminal
4. El código exacto a escribir o modificar

Aquí está la información sobre los archivos relevantes del proyecto:
]] .. files_info .. [[

Formatea tu respuesta como una lista numerada de pasos. Sé específico y detallado.
  ]]

  -- Sistema prompt para planificación
  local system_prompt = [[Eres un asistente de programación experto que ayuda a planificar y ejecutar tareas de codificación complejas.
Tu trabajo es analizar la tarea solicitada, comprender el código del proyecto y proporcionar un plan paso a paso detallado.
Cada paso debe ser claro, conciso y ejecutable. Debes ser específico sobre qué archivos modificar y qué código cambiar.
]]

  local total_tokens = 0
  local plan_response = ""

  Llm._stream({
    ask = true,
    code_lang = "unknown",
    provider = Providers[Config.provider],
    prompt_opts = {
      system_prompt = system_prompt,
      tools = {},
      messages = {
        { role = "user", content = planning_prompt },
      },
    },
    on_start = function(_) end,
    on_chunk = function(chunk)
      if not chunk then return end
      plan_response = plan_response .. chunk
      total_tokens = total_tokens + (#vim.split(chunk, " ") * 1.3)
    end,
    on_stop = function(stop_opts)
      if stop_opts.error ~= nil then
        local err = string.format("Agent planning failed: %s", vim.inspect(stop_opts.error))
        if on_log then on_log(err) end
        on_complete(nil, err)
        return
      end

      -- Parsear los pasos desde la respuesta
      local steps = parse_steps_from_response(plan_response)
      agent_state.steps = steps

      -- Mostrar plan al usuario
      local plan_text = "Plan para: " .. agent_state.task .. "\n\n" .. plan_response

      -- Mostrar UI para confirmar plan
      show_plan_ui(plan_text,
        function()
          -- Callback para confirmar
          if on_log then on_log("Plan confirmado, ejecutando...") end
          execute_next_step(on_log, on_complete)
        end,
        function()
          -- Callback para cancelar
          agent_state.active = false
          if on_log then on_log("Plan cancelado por el usuario.") end
          on_complete("Plan cancelado por el usuario.", nil)
        end
      )
    end,
  })
end

-- Ejecutar el siguiente paso
local function execute_next_step(on_log, on_complete)
  if not agent_state.active or agent_state.current_step > #agent_state.steps then
    agent_state.active = false
    if on_log then on_log("¡Tarea completada!") end
    on_complete("Tarea completada con éxito.", nil)
    return
  end

  local step = agent_state.steps[agent_state.current_step]
  if on_log then on_log("Ejecutando paso " .. agent_state.current_step .. ": " .. step.description) end

  -- Incrementar contador de pasos
  agent_state.current_step = agent_state.current_step + 1

  -- Por simplicidad, avanzar al siguiente paso
  -- En una implementación completa, aquí procesaríamos las acciones específicas del paso

  -- Programar el siguiente paso
  vim.defer_fn(function()
    execute_next_step(on_log, on_complete)
  end, 1000)
end

---@type AvanteLLMToolFunc<{ prompt: string }>
function M.func(opts, on_log, on_complete)
  if not on_complete then return false, "on_complete not provided" end

  local prompt = opts.prompt
  local file_paths = opts.file_paths or {}

  -- Iniciar el agente
  start_agent(prompt, file_paths, on_log, on_complete)

  return true
end

return M
