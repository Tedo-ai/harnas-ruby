#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "harnas/conformance/provider_stream_runner"

options = {
  spec: ENV.fetch(
    "HARNAS_SPEC",
    File.expand_path("../../harnas", __dir__)
  )
}
OptionParser.new do |parser|
  parser.on("--spec PATH", "Path to the harnas specification checkout") do |path|
    options[:spec] = path
  end
end.parse!

report = Harnas::Conformance::ProviderStreamRunner.run(options.fetch(:spec))
warn "#{report.cases}/#{report.cases} provider-wire cases; " \
     "#{report.profiles} chunked executions passed"
