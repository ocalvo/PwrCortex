# ══════════════════════════════════════════════════════════════════════════════
#  AGENTIC LOOP HELPERS — Tool call extraction and result building
# ══════════════════════════════════════════════════════════════════════════════

function script:Extract-AnthropicToolCalls($RawContent) {
    $RawContent | Where-Object { $_.type -eq 'tool_use' }
}

function script:Extract-AnthropicText($RawContent) {
    ($RawContent | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
}

function script:Build-AnthropicToolResult($ToolUseId, $Output) {
    @{ type='tool_result'; tool_use_id=$ToolUseId; content=$Output }
}

function script:Extract-OpenAIToolCalls($Choice) {
    $Choice.message.tool_calls
}

function script:Build-OpenAIToolResult($ToolCallId, $Output) {
    @{ role='tool'; tool_call_id=$ToolCallId; content=$Output }
}
