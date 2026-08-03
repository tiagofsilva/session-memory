# frozen_string_literal: true

require "spec_helper"
require "json"
require "fileutils"

RSpec.describe SessionMemory::Installer do
  around do |example|
    Dir.mktmpdir do |home|
      @home = home
      @store = File.join(home, ".session-memory")
      ENV["SESSION_MEMORY_HOME"] = @store
      example.run
    ensure
      ENV.delete("SESSION_MEMORY_HOME")
    end
  end

  def installer
    SessionMemory::Installer.new(home: @home)
  end

  it "merges into an existing cursor hooks.json without dropping other hooks" do
    path = File.join(@home, ".cursor", "hooks.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate({
      "version" => 1,
      "hooks" => {
        "afterFileEdit" => [{ "command" => "./hooks/format.sh" }],
        "beforeSubmitPrompt" => [{ "command" => "./hooks/other.sh" }],
      },
    }))

    installer.install!

    data = JSON.parse(File.read(path))
    expect(data["hooks"]["afterFileEdit"]).to eq([{ "command" => "./hooks/format.sh" }])
    expect(data["hooks"]["beforeSubmitPrompt"].map { |e| e["command"] }).to include("./hooks/other.sh")
    expect(data["hooks"]["beforeSubmitPrompt"].any? { |e| e["command"].include?("session-memory hook cursor") }).to be(true)
    expect(data["hooks"]["sessionStart"]).not_to be_empty
    expect(data["hooks"]["stop"]).not_to be_empty
  end

  it "is idempotent when run twice" do
    installer.install!
    path = File.join(@home, ".cursor", "hooks.json")
    first = JSON.parse(File.read(path))
    SessionMemory::Installer.new(home: @home).install!
    second = JSON.parse(File.read(path))

    expect(second["hooks"]["beforeSubmitPrompt"].size).to eq(first["hooks"]["beforeSubmitPrompt"].size)
    expect(File.directory?(@store)).to be(true)
    expect(File.stat(@store).mode & 0o777).to eq(0o700)
  end

  it "detects missing codex feature flag without rewriting config.toml" do
    config = File.join(@home, ".codex", "config.toml")
    FileUtils.mkdir_p(File.dirname(config))
    original = "model = \"gpt-x\"\n"
    File.write(config, original)

    installer.install!

    expect(File.read(config)).to eq(original)
    expect(File.exist?(File.join(@home, ".codex", "hooks.json"))).to be(true)
  end

  it "uninstall removes our entries and leaves the store" do
    installer.install!
    FileUtils.mkdir_p(File.join(@store, "sessions", "demo"))
    File.write(File.join(@store, "sessions", "demo", "x.digest.md"), "keep")

    SessionMemory::Installer.new(home: @home).uninstall!

    data = JSON.parse(File.read(File.join(@home, ".cursor", "hooks.json")))
    expect(Array(data.dig("hooks", "beforeSubmitPrompt")).none? { |e| e["command"].include?("session-memory") }).to be(true)
    expect(File.exist?(File.join(@store, "sessions", "demo", "x.digest.md"))).to be(true)
  end
end
