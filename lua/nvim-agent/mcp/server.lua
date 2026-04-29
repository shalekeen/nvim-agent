#!/usr/bin/env luajit
-- MCP Server for Neovim Control
-- Implements JSON-RPC 2.0 over stdio

-- Set up package path to find local modules
local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
if script_dir then
  package.path = script_dir .. "?.lua;" .. package.path
end

local json = require("dkjson")
local tools = require("tools")

-- JSON-RPC error codes
local ERROR_CODES = {
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL_ERROR = -32603
}

-- Server state
local server_info = {
  name = "nvim-agent-mcp",
  version = "1.0.0"
}

-- Write a JSON-RPC response to stdout
local function write_response(response)
  local encoded = json.encode(response)
  if not encoded then
    io.stderr:write("ERROR: Failed to encode response\n")
    return
  end
  io.write(encoded .. "\n")
  io.flush()
end

-- Send a JSON-RPC error response
local function send_error(id, code, message, data)
  write_response({
    jsonrpc = "2.0",
    id = id,
    error = {
      code = code,
      message = message,
      data = data
    }
  })
end

-- Send a JSON-RPC success response
local function send_result(id, result)
  write_response({
    jsonrpc = "2.0",
    id = id,
    result = result
  })
end

-- Handle initialize method
local function handle_initialize(id, params)
  -- Use dkjson.empty_object to ensure tools is encoded as {} not []
  local capabilities = {
    tools = json.empty_object or setmetatable({}, {__jsontype = "object"})
  }

  send_result(id, {
    protocolVersion = "2024-11-05",
    serverInfo = server_info,
    capabilities = capabilities
  })
end

-- Handle tools/list method
local function handle_tools_list(id, params)
  local tool_list = tools.list()
  send_result(id, {
    tools = tool_list
  })
end

-- Handle tools/call method
local function handle_tools_call(id, params)
  if not params or not params.name then
    send_error(id, ERROR_CODES.INVALID_PARAMS, "Missing tool name")
    return
  end

  local tool_name = params.name
  local arguments = params.arguments or {}

  -- Execute the tool
  local content, is_error = tools.execute(tool_name, arguments)

  if is_error then
    send_result(id, {
      content = content,
      isError = true
    })
  else
    send_result(id, {
      content = content
    })
  end
end

-- Route a request to the appropriate handler
local function handle_request(request)
  -- Validate JSON-RPC 2.0
  if request.jsonrpc ~= "2.0" then
    send_error(request.id, ERROR_CODES.INVALID_REQUEST, "Invalid JSON-RPC version")
    return
  end

  local method = request.method
  local id = request.id
  local params = request.params

  if method == "initialize" then
    handle_initialize(id, params)
  elseif method == "tools/list" then
    handle_tools_list(id, params)
  elseif method == "tools/call" then
    handle_tools_call(id, params)
  else
    send_error(id, ERROR_CODES.METHOD_NOT_FOUND, "Method not found: " .. tostring(method))
  end
end

-- Main server loop
local function main()
  -- Check for NVIM_LISTEN_ADDRESS
  local nvim_addr = os.getenv("NVIM_LISTEN_ADDRESS")
  if not nvim_addr or nvim_addr == "" then
    -- Silent fail - just exit without sending anything
    -- Can't send error without a request ID
    os.exit(1)
  end

  -- Don't write to stderr - it causes Claude Code to think the server failed
  -- MCP protocol uses only stdin/stdout for JSON-RPC communication

  -- Read and process requests line by line
  for line in io.lines() do
    if line and line ~= "" then
      -- Parse JSON request
      local request, pos, err = json.decode(line)

      if err then
        -- Skip malformed requests silently - can't send error without valid request
        -- Claude Code rejects error responses with null IDs
      else
        -- Handle the request in protected mode
        local ok, error_msg = pcall(handle_request, request)
        if not ok then
          -- Send error response instead of writing to stderr
          send_error(request.id, ERROR_CODES.INTERNAL_ERROR, "Internal error: " .. tostring(error_msg))
        end
      end
    end
  end
end

-- Run the server
main()
