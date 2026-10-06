# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Explicit trace ID roots" do
  let(:exporter) { OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
  let(:trace_id) { Langfuse.create_trace_id(seed: "request-125") }

  before do
    Langfuse.configure do |config|
      config.span_exporter = exporter
      config.tracing_async = false
    end
  end

  def exported_spans
    Langfuse.force_flush(timeout: 2)
    exporter.finished_spans
  end

  it "exports repeated trace IDs as actual roots with distinct observation IDs" do
    2.times { Langfuse.observe("request", trace_id: trace_id) { :result } }

    spans = exported_spans
    expect(spans.size).to eq(2)
    expect(spans.map(&:hex_trace_id)).to eq([trace_id, trace_id])
    expect(spans.map(&:span_id).uniq.size).to eq(2)
    expect(spans.map(&:parent_span_id)).to all(eq(OpenTelemetry::Trace::INVALID_SPAN_ID))
    expect(spans.map(&:attributes)).to all(include(Langfuse::OtelAttributes::IS_APP_ROOT => true))
  end

  it "detaches a seeded root from an ambient span and preserves ordinary nesting" do
    Langfuse.observe("ambient") do |ambient|
      Langfuse.observe("seeded", trace_id: trace_id) do |root|
        Langfuse.observe("nested") { :child }
        expect(root.trace_id).to eq(trace_id)
      end
      Langfuse.observe("sibling") { :sibling }
      expect(OpenTelemetry::Trace.current_span).to equal(ambient.otel_span)
    end

    spans = exported_spans.to_h { |span| [span.name, span] }
    expect(spans["seeded"].parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
    expect(spans["nested"].parent_span_id).to eq(spans["seeded"].span_id)
    expect(spans["sibling"].parent_span_id).to eq(spans["ambient"].span_id)
    expect(spans["sibling"].trace_id).to eq(spans["ambient"].trace_id)
  end

  it "uses the configured root sampler rather than inventing a sampled parent" do
    Langfuse.tracer_provider.sampler = OpenTelemetry::SDK::Trace::Samplers.parent_based(
      root: OpenTelemetry::SDK::Trace::Samplers::ALWAYS_OFF
    )

    observation = Langfuse.observe("dropped", trace_id: trace_id) { |root| root }

    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span.context.trace_flags.sampled?).to be(false)
    expect(exported_spans).to be_empty
  end

  it "preserves correlation when the captured provider shuts down before root creation" do
    context = OpenTelemetry::Context.current
    allow(Langfuse::OtelSetup).to receive(:start_root_span).and_wrap_original do |original, *arguments, **keywords|
      Langfuse::OtelSetup.shutdown(timeout: 2)
      original.call(*arguments, **keywords)
    end

    observation = Langfuse.observe("shutdown-root", trace_id: trace_id) { |root| root }

    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span.recording?).to be(false)
    expect(OpenTelemetry::Context.current).to equal(context)
  end

  it "uses the captured generator when a replacement provider starts before root creation" do
    context = OpenTelemetry::Context.current
    allow(Langfuse).to receive(:otel_tracer).and_wrap_original do |original, &block|
      captured = original.call(&block)
      Langfuse::OtelSetup.shutdown(timeout: 2)
      Langfuse.configure { |config| config.span_exporter = OpenTelemetry::SDK::Trace::Export::InMemorySpanExporter.new }
      Langfuse.tracer_provider
      captured
    end

    observation = Langfuse.observe("replaced-root", trace_id: trace_id) { |root| root }

    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span.recording?).to be(false)
    expect(OpenTelemetry::Context.current).to equal(context)
  end

  it "preserves correlation when the application replaces the provider's ID generator" do
    Langfuse.tracer_provider.id_generator = OpenTelemetry::Trace

    observation = Langfuse.observe("custom-generator", trace_id: trace_id) { |root| root }

    expect(observation.trace_id).to eq(trace_id)
    expect(exported_spans.first.hex_trace_id).to eq(trace_id)
  end

  it "preserves propagated attributes, baggage, input, output, and timestamps" do
    started = Time.now - 1
    Langfuse.configure { |config| config.release = "configured-release" }
    Langfuse.propagate_attributes(
      user_id: "user-125", session_id: "session-125", trace_name: "workflow", as_baggage: true
    ) do
      observation = Langfuse.start_observation("request", { input: { question: "hello" } },
                                               trace_id: trace_id, start_time: started)
      observation.update(output: { answer: "world" })
      observation.end
    end

    span = exported_spans.first
    expect(span.start_timestamp).to eq((started.to_r * 1_000_000_000).to_i)
    expect(span.attributes).to include(
      "user.id" => "user-125", "session.id" => "session-125", "langfuse.trace.name" => "workflow",
      "langfuse.release" => "configured-release", "langfuse.observation.input" => '{"question":"hello"}',
      "langfuse.observation.output" => '{"answer":"world"}'
    )
  end

  it "restores ambient context after block and span-start exceptions" do
    Langfuse.observe("ambient") do |ambient|
      context = OpenTelemetry::Context.current
      expect do
        Langfuse.observe("raises", trace_id: trace_id) { raise "block failure" }
      end.to raise_error("block failure")
      expect(OpenTelemetry::Context.current).to equal(context)

      sampler = Langfuse.tracer_provider.sampler
      allow(sampler).to receive(:should_sample?).and_raise("start failure")
      expect do
        Langfuse.start_observation("start-raises", trace_id: trace_id)
      end.to raise_error("start failure")
      expect(OpenTelemetry::Trace.current_span).to equal(ambient.otel_span)
      expect(OpenTelemetry::Context.current).to equal(context)
      allow(sampler).to receive(:should_sample?).and_call_original
    end

    after = Langfuse.start_observation("after")
    expect(after.trace_id).not_to eq(trace_id)
    after.end
  end

  it "preserves an explicit real parent even when a different ambient span is active" do
    parent = Langfuse.start_observation("parent")
    Langfuse.observe("ambient") do
      child = Langfuse.start_observation("child", parent_span_context: parent.otel_span.context)
      child.end
    end
    parent.end

    spans = exported_spans.to_h { |span| [span.name, span] }
    expect(spans["child"].parent_span_id).to eq(spans["parent"].span_id)
    expect(spans["child"].trace_id).to eq(spans["parent"].trace_id)
  end

  it "keeps the external global tracer provider and its unseeded roots independent" do
    global_provider = OpenTelemetry.tracer_provider
    global_propagation = OpenTelemetry.propagation
    global_tracer = global_provider.tracer("external")
    sampler = OpenTelemetry::SDK::Trace::Samplers::TraceIdRatioBased.new(1.0)
    Langfuse.tracer_provider.sampler = sampler
    external = nil
    allow(sampler).to receive(:should_sample?).and_wrap_original do |original, **arguments|
      parentless = OpenTelemetry::Trace.context_with_span(OpenTelemetry::Trace::Span::INVALID)
      external = global_tracer.start_span("external", with_parent: parentless)
      external.finish
      original.call(**arguments)
    end
    Langfuse.observe("request", trace_id: trace_id) { :result }

    expect(external.context.trace_id.unpack1("H*")).not_to eq(trace_id)
    expect(OpenTelemetry.tracer_provider).to equal(global_provider)
    expect(OpenTelemetry.propagation).to equal(global_propagation)
  end

  it "keeps telemetry-disabled observations non-recording while validating trace IDs" do
    Langfuse.configure { |config| config.tracing_enabled = false }

    expect(Langfuse.observe("disabled", trace_id: trace_id) { :business_result }).to eq(:business_result)
    observation = Langfuse.start_observation("disabled", trace_id: trace_id)
    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span.recording?).to be(false)
    expect { Langfuse.start_observation("invalid", trace_id: "0" * 32) }.to raise_error(ArgumentError)
    expect(exported_spans).to be_empty
  end

  it "retains no-op correlation after disabling an initialized provider" do
    Langfuse.tracer_provider
    Langfuse.configure { |config| config.tracing_enabled = false }

    observation = Langfuse.start_observation("disabled", trace_id: trace_id)

    expect(observation.trace_id).to eq(trace_id)
    expect(observation.otel_span.recording?).to be(false)
    expect(exported_spans).to be_empty
  end

  it "starts a fresh application root even inside another root with the same trace ID" do
    Langfuse.observe("outer", trace_id: trace_id) do
      Langfuse.observe("inner", trace_id: trace_id) { :inner }
    end

    expect(exported_spans.map(&:parent_span_id)).to all(eq(OpenTelemetry::Trace::INVALID_SPAN_ID))
    expect(exported_spans.map(&:attributes)).to all(include(Langfuse::OtelAttributes::IS_APP_ROOT => true))
  end

  it "keeps interleaved fibers independent" do
    other_id = Langfuse.create_trace_id(seed: "other-fiber")
    fibers = [trace_id, other_id].map do |id|
      Fiber.new do
        Langfuse.observe(id, trace_id: id) do |root|
          Fiber.yield
          Langfuse.observe("child-#{id}") { :child }
          expect(OpenTelemetry::Trace.current_span).to equal(root.otel_span)
        end
      end
    end
    fibers.each(&:resume)
    expect(OpenTelemetry::Trace.current_span.context).not_to be_valid
    fibers.reverse_each(&:resume)

    spans = exported_spans
    [trace_id, other_id].each do |id|
      parent = spans.find { |span| span.name == id }
      child = spans.find { |span| span.name == "child-#{id}" }
      expect(parent.hex_trace_id).to eq(id)
      expect(child.parent_span_id).to eq(parent.span_id)
      expect(child.trace_id).to eq(parent.trace_id)
    end
  end

  it "keeps roots and their children independent across bounded threads" do
    ids = [trace_id, Langfuse.create_trace_id(seed: "other-thread")]
    threads = ids.map do |id|
      Thread.new do
        Langfuse.observe(id, trace_id: id) { Langfuse.observe("child-#{id}") { :child } }
      end
    end
    threads.each(&:value)

    spans = exported_spans
    ids.each do |id|
      parent = spans.find { |span| span.name == id }
      child = spans.find { |span| span.name == "child-#{id}" }
      expect(parent.hex_trace_id).to eq(id)
      expect(parent.parent_span_id).to eq(OpenTelemetry::Trace::INVALID_SPAN_ID)
      expect(child.parent_span_id).to eq(parent.span_id)
      expect(child.trace_id).to eq(parent.trace_id)
    end
  ensure
    threads&.each(&:join)
  end

  it "sends parentless seeded roots and observation IO over direct v4 OTLP" do
    Langfuse.configure { |config| config.span_exporter = nil }
    requests = []
    stub_request(:post, "https://cloud.langfuse.com/api/public/otel/v1/traces")
      .with(headers: { "X-Langfuse-Ingestion-Version" => "4", "Content-Encoding" => "gzip" })
      .to_return do |request|
        requests << Zlib.gunzip(request.body)
        { status: 200, body: "" }
      end

    Langfuse.observe("request", trace_id: trace_id, input: "question") do |root|
      root.start_observation("child") { :child }
      root.update(output: "answer")
    end
    Langfuse.force_flush(timeout: 2)

    message = Opentelemetry::Proto::Collector::Trace::V1::ExportTraceServiceRequest.decode(requests.fetch(0))
    spans = message.resource_spans.flat_map { |resource| resource.scope_spans.flat_map(&:spans) }
    root = spans.find { |span| span.name == "request" }
    child = spans.find { |span| span.name == "child" }
    attributes = root.attributes.to_h { |attribute| [attribute.key, attribute.value] }
    expect(root.trace_id.unpack1("H*")).to eq(trace_id)
    expect(root.parent_span_id).to eq("")
    expect(child.parent_span_id).to eq(root.span_id)
    expect(attributes["langfuse.internal.is_app_root"].bool_value).to be(true)
    expect(attributes["langfuse.observation.input"].string_value).to eq("question".to_json)
    expect(attributes["langfuse.observation.output"].string_value).to eq("answer".to_json)
  end
end
