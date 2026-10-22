//! The pack product operations and the values their callers use.

const build_info = @import("build_info");
const request = @import("products/pack/input/scenario/request");
const sources = @import("products/pack/input/sources");
const names = @import("phb/model/names");
const publications = @import("simulation/model/publications");
const configuration = @import("simulation/model/config");
const power = @import("simulation/model/power");
const request_reader = @import("products/pack/input/scenario/read");
const pipeline = @import("products/pack/pipeline");
const diagnostics = @import("base/diagnostics");
const coverage = @import("products/pack/planning/coverage");
const bundle_file = @import("phb/model/file");
const bundle_writer = @import("phb/write");
const prepared_scenario = @import("simulation/model/prepared_scenario");
const prepared_bundle = @import("phb/prepared");
const display = @import("phb/model/display");
const flight_plan = @import("simulation/model/flight_plan");
const bundle_reader = @import("phb/read");
const gnss_types = @import("domain/gnss_types");
const time = @import("domain/time/gps");
const sampling = @import("simulation/model/sampling");

pub const version = build_info.version;
pub const source_digest = build_info.source_digest;

pub const Request = request.Request;
pub const IonosphereSelection = request.Ionosphere;
pub const InputFile = sources.File;
pub const InputSource = sources.Source;
pub const NavFile = names.NavFile;
pub const NavKind = names.NavKind;
pub const PreciseInput = request.Precise;
pub const MessageConfig = publications.Publications;
pub const HasConfig = configuration.Has;
pub const HasStatus = configuration.HasStatus;
pub const PppB2bConfig = configuration.PppB2b;
pub const ObservationConfig = configuration.Observation;
pub const PositionConfig = configuration.Position;
pub const PositionFormat = configuration.PositionFormat;
pub const PowerConfig = power.Config;
pub const PowerEntry = power.Entry;
pub const readRequest = request_reader.readRequest;

pub const Assembled = pipeline.Assembled;
pub const LoadError = diagnostics.LoadError;
pub const assemble = pipeline.assemble;
pub const NavigationCoverage = coverage.Covered;
pub const describeNavigation = pipeline.describe;

pub const File = bundle_file.File;
pub const writePhb = bundle_writer.write;
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
pub const SatSet = gnss_types.SatSet;
pub const PowerUnit = power.Unit;
pub const PowerLevel = power.Level;
pub const PowerTarget = power.Target;
pub const Samples = configuration.Samples;
pub const SampleRate = sampling.SampleRate;
pub const Hz = sampling.Hz;
pub const IqFormat = sampling.IqFormat;

pub const Diagnostics = diagnostics.Diagnostics;
pub const Diagnostic = diagnostics.Diagnostic;
pub const DiagnosticCode = diagnostics.Code;
pub const DiagnosticCategory = diagnostics.Category;
pub const Severity = diagnostics.Severity;
pub const DiagnosticLocation = diagnostics.Location;
pub const DiagnosticScope = diagnostics.Scope;
pub const InputError = diagnostics.InputError;
