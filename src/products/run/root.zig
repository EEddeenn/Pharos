//! The run product operations and the values their callers use.

const build_info = @import("build_info");
const engine = @import("products/run/engine/run");
const gain = @import("products/run/synthesis/gain");
const command = @import("simulation/model/command");
const commands = @import("products/run/engine/commands");
const events = @import("products/run/engine/events");
const sink = @import("products/run/output/sink");
const manifest = @import("products/run/output/manifest");
const dump = @import("products/run/output/dump");
const tag = @import("products/run/output/tag");
const prepared_scenario = @import("simulation/model/prepared_scenario");
const prepared_bundle = @import("phb/prepared");
const display = @import("phb/model/display");
const flight_plan = @import("simulation/model/flight_plan");
const bundle_reader = @import("phb/read");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const power = @import("simulation/model/power");
const configuration = @import("simulation/model/config");
const sampling = @import("simulation/model/sampling");
const ionosphere_state = @import("simulation/state/ionosphere");
const diagnostics = @import("base/diagnostics");

pub const version = build_info.version;
pub const source_digest = build_info.source_digest;

pub const Run = engine.Run;
pub const Options = engine.Options;
pub const DumpWriters = engine.DumpWriters;
pub const Info = engine.Info;
pub const Status = engine.Status;
pub const Block = engine.Block;
pub const NoiseMode = engine.NoiseMode;
pub const GainDb = gain.Db;
pub const GainMode = gain.Mode;
pub const GainSetting = engine.GainSetting;
pub const GainStatus = engine.GainStatus;
pub const CreateError = engine.CreateError;
pub const GenerationError = engine.GenerationError;
pub const PullError = engine.PullError;
pub const SeekError = engine.SeekError;
pub const reason = engine.reason;

pub const Command = command.Command;
pub const CommandAction = command.Action;
pub const CommandKind = command.Kind;
pub const Applied = commands.Applied;
pub const SubmitError = commands.SubmitError;
pub const command_capacity = commands.capacity;
pub const Event = events.Event;
pub const EventKind = events.Kind;
pub const GainAdjustment = gain.Adjustment;

pub const Written = sink.Written;
pub const writeRun = sink.writeRun;
pub const ManifestMetadata = manifest.Metadata;
pub const writeManifest = manifest.write;
pub const writeScenario = dump.writeScenario;
pub const tagText = tag.text;
pub const tag_max_len = tag.max_len;

pub const PreparedScenario = prepared_scenario.PreparedScenario;
pub const PreparedBundle = prepared_bundle.PreparedBundle;
pub const Display = display.Display;
pub const Span = prepared_scenario.Span;
pub const FlightPlan = flight_plan.FlightPlan;
pub const readPreparedBundle = bundle_reader.read;

pub const System = gnss_types.System;
pub const Signal = gnss_types.Signal;
pub const SatId = gnss_types.SatId;
pub const GpsTime = time.GpsTime;
pub const Epoch = time.Epoch;
pub const PowerUnit = power.Unit;
pub const PowerLevel = power.Level;
pub const PowerTarget = power.Target;
pub const ChannelKey = gnss_types.ChannelKey;
pub const Samples = configuration.Samples;
pub const SampleRate = sampling.SampleRate;
pub const Hz = sampling.Hz;
pub const IqFormat = sampling.IqFormat;
pub const IonosphereInfo = ionosphere_state.Info;

pub const Diagnostics = diagnostics.Diagnostics;
pub const Diagnostic = diagnostics.Diagnostic;
pub const DiagnosticCode = diagnostics.Code;
pub const DiagnosticCategory = diagnostics.Category;
pub const Severity = diagnostics.Severity;
pub const DiagnosticLocation = diagnostics.Location;
pub const DiagnosticScope = diagnostics.Scope;
pub const InputError = diagnostics.InputError;
