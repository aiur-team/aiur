#!/usr/bin/env ruby
# Ruby's standard YAML parser reads the checked-in operator policy, never PR code.
require 'json'
require 'yaml'

policy = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false).fetch('merge_policy', {})
labels = policy.fetch('full_ci_labels', ['main-fix'])
patterns = policy.fetch('full_ci_paths', [])
raise 'full_ci_labels/full_ci_paths must be string arrays' unless [labels, patterns].all? { |list| list.is_a?(Array) && list.all? { |v| v.is_a?(String) && !v.empty? } }
pr = JSON.parse(File.read(ARGV.fetch(1)))
files = JSON.parse(File.read(ARGV.fetch(2)))
paths = files.flat_map { |file| [file.fetch('filename'), file['previous_filename']].compact }
gate_paths = %w(scripts/check-ci-gate.py scripts/classify-ci-changes.sh scripts/ci-policy.rb scripts/ci-test-selection.exs scripts/run-ci-affected-tests.py src/lib/aiur/affected_tests.ex src/lib/mix/tasks/aiur.affected_tests.ex)
browser_paths = %w(.github/workflows/ci.yml scripts/check-ci-gate.py scripts/ci-policy.rb scripts/classify-ci-changes.sh src/browser/** src/lib/aiur_web/** src/priv/static/**)
full = paths.empty? || files.length >= 3000 || paths.any? { |path| gate_paths.include?(path) } || pr.fetch('labels').any? do |label|
  label_name = label.fetch('name')
  label_name.casecmp?('ci:full') || labels.any? { |configured| configured.casecmp?(label_name) }
end
full ||= patterns.any? do |glob|
  regex = Regexp.escape(glob).gsub('\\*\\*/', '(?:.*/)?').gsub('\\*\\*', '.*').gsub('\\*', '[^/]*').gsub('\\?', '[^/]')
  paths.any? { |path| Regexp.new("\\A#{regex}\\z", Regexp::MULTILINE).match?(path) }
end
puts "full_ci=#{full}"
browser_smoke = paths.any? do |path|
  browser_paths.any? do |glob|
    regex = Regexp.escape(glob).gsub('\\*\\*/', '(?:.*/)?').gsub('\\*\\*', '.*').gsub('\\*', '[^/]*')
    Regexp.new("\\A#{regex}\\z").match?(path)
  end
end
puts "browser_smoke=#{browser_smoke}"
docs_only = !full && paths.all? { |path| path.start_with?('website/', 'packages/aiur-style/') }
puts "docs_only=#{docs_only}"
