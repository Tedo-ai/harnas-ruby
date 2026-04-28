# frozen_string_literal: true

require "harnas/events/assistant_turn_started"
require "harnas/events/assistant_text_delta"
require "harnas/events/tool_use_begin"
require "harnas/events/tool_use_argument_delta"
require "harnas/events/tool_use_end"
require "harnas/events/assistant_turn_completed"
require "harnas/events/assistant_turn_failed"

RSpec.describe Harnas::Events::AssistantTurnStarted do
  it "holds turn_id" do
    expect(described_class.new(turn_id: "t1").turn_id).to eq("t1")
  end

  it "rejects a non-String turn_id" do
    expect { described_class.new(turn_id: 1) }
      .to raise_error(ArgumentError, /turn_id must be a String/)
  end

  it "rejects an empty turn_id" do
    expect { described_class.new(turn_id: "") }
      .to raise_error(ArgumentError, /turn_id must not be empty/)
  end
end

RSpec.describe Harnas::Events::AssistantTextDelta do
  it "holds turn_id and chunk" do
    e = described_class.new(turn_id: "t1", chunk: "Hell")
    expect(e.turn_id).to eq("t1")
    expect(e.chunk).to eq("Hell")
  end

  it "accepts an empty chunk" do
    expect { described_class.new(turn_id: "t1", chunk: "") }.not_to raise_error
  end

  it "rejects a non-String chunk" do
    expect { described_class.new(turn_id: "t1", chunk: nil) }
      .to raise_error(ArgumentError, /chunk must be a String/)
  end
end

RSpec.describe Harnas::Events::ToolUseBegin do
  it "holds turn_id, tool_use_id, and name" do
    e = described_class.new(turn_id: "t1", tool_use_id: "toolu_1", name: "echo")
    expect(e.tool_use_id).to eq("toolu_1")
    expect(e.name).to eq("echo")
  end

  it "rejects an empty name" do
    expect { described_class.new(turn_id: "t1", tool_use_id: "toolu_1", name: "") }
      .to raise_error(ArgumentError, /name must be a non-empty String/)
  end
end

RSpec.describe Harnas::Events::ToolUseArgumentDelta do
  it "holds turn_id, tool_use_id, and a partial-JSON chunk" do
    e = described_class.new(turn_id: "t1", tool_use_id: "toolu_1", chunk: '{"tex')
    expect(e.chunk).to eq('{"tex')
  end

  it "accepts an empty chunk" do
    expect do
      described_class.new(turn_id: "t1", tool_use_id: "toolu_1", chunk: "")
    end.not_to raise_error
  end
end

RSpec.describe Harnas::Events::ToolUseEnd do
  it "holds turn_id, tool_use_id, and assembled arguments Hash" do
    e = described_class.new(turn_id: "t1", tool_use_id: "toolu_1", arguments: { text: "hi" })
    expect(e.arguments).to eq({ text: "hi" })
  end

  it "rejects a non-Hash arguments" do
    expect do
      described_class.new(turn_id: "t1", tool_use_id: "toolu_1", arguments: "nope")
    end.to raise_error(ArgumentError, /arguments must be a Hash/)
  end
end

RSpec.describe Harnas::Events::AssistantTurnCompleted do
  it "holds turn_id, stop_reason, usage" do
    e = described_class.new(
      turn_id: "t1", stop_reason: :end_turn, usage: { input_tokens: 5, output_tokens: 3 }
    )
    expect(e.stop_reason).to eq(:end_turn)
  end

  it "defaults usage to empty Hash" do
    e = described_class.new(turn_id: "t1", stop_reason: :end_turn)
    expect(e.usage).to eq({})
  end

  it "rejects an unknown stop_reason" do
    expect { described_class.new(turn_id: "t1", stop_reason: :wat) }
      .to raise_error(ArgumentError, /stop_reason must be one of/)
  end
end

RSpec.describe Harnas::Events::AssistantTurnFailed do
  it "holds turn_id and error" do
    e = described_class.new(turn_id: "t1", error: "connection closed")
    expect(e.error).to eq("connection closed")
  end

  it "rejects an empty error" do
    expect { described_class.new(turn_id: "t1", error: "") }
      .to raise_error(ArgumentError, /error must be a non-empty String/)
  end
end
