# frozen_string_literal: true

require "test_helper"

class ScorerTest < ActiveSupport::TestCase
  def application(serial, beverage_type: "malt", net_contents: "750 mL")
    app = LabelApplication.new(
      serial_number: serial, brand_name: "BRAND #{serial}", beverage_type: beverage_type,
      applicant_name_address: "Someone, Somewhere, KY", net_contents: net_contents,
      channel: "submitted"
    )
    app.artwork.attach(io: StringIO.new("bytes-#{serial}"), filename: "l.png", content_type: "image/png")
    app.save!
    app
  end

  def verify(app, model_id:, checks:, verdict: nil, created_at: Time.current)
    app.verifications.create!(
      overall_verdict: verdict || FieldCheck.overall(checks),
      field_checks: checks,
      extraction: { "fields" => {} },
      model_id: model_id,
      created_at: created_at
    )
  end

  def check(field, verdict, note: nil)
    FieldCheck.new(field: field, verdict: verdict, expected: nil, extracted: nil, citation: "test", note: note)
  end

  test "positives split clean, flagged, other, and unverified per model, latest verification wins" do
    clean = application("POS-1")
    flagged = application("POS-2")
    retake = application("POS-3")
    unverified = application("POS-4")

    verify(clean, model_id: "model-a", checks: [ check("brand_name", "fail") ], created_at: 2.hours.ago)
    verify(clean, model_id: "model-a", checks: [ check("brand_name", "pass") ], created_at: 1.hour.ago)
    verify(clean, model_id: "model-b", checks: [ check("brand_name", "fail") ])
    verify(flagged, model_id: "model-a", checks: [ check("brand_name", "needs_review", note: "mismatch") ])
    verify(retake, model_id: "model-a", checks: [], verdict: "request_retake")

    result = EvalCorpus::Scorer.score_model(
      parents: [ clean, flagged, retake, unverified ], mutants: [], model_id: "model-a"
    )

    assert_equal [ clean ], result[:positives][:clean]
    assert_equal [ flagged ], result[:positives][:flagged].map { |e| e[:application] }
    assert_equal "needs_review", result[:positives][:flagged].first[:checks].first.verdict
    assert_equal [ retake ], result[:positives][:other].map { |e| e[:application] }
    assert_equal [ unverified ], result[:positives][:unverified]
  end

  test "the sentinel net-contents review is excluded for registry positives only" do
    sentinel_app = application("POS-SENT", net_contents: EvalCorpus::RegistryRecord::NET_CONTENTS_SENTINEL)
    concrete_app = application("POS-CONC")
    sentinel_checks = [
      check("brand_name", "pass"),
      check("net_contents", "needs_review", note: EvalCorpus::Scorer::SENTINEL_NOTE)
    ]
    verify(sentinel_app, model_id: "m", checks: sentinel_checks)
    verify(concrete_app, model_id: "m", checks: sentinel_checks)

    result = EvalCorpus::Scorer.score_model(parents: [ sentinel_app, concrete_app ], mutants: [], model_id: "m")

    assert_equal [ sentinel_app ], result[:positives][:clean], "sentinel review excluded for the registry record"
    assert_equal [ concrete_app ], result[:positives][:flagged].map { |e| e[:application] },
                 "a concrete declaration keeps the same check as a real flag"
  end

  test "negatives classify caught, missed, and unverified by mutation type" do
    parent = application("PAR-1")
    caught = application("PAR-1-MUT-BRAND")
    missed = application("PAR-1-MUT-NET")
    unverified = application("PAR-1-MUT-FANCIFUL")

    verify(caught, model_id: "m", checks: [ check("brand_name", "fail", note: "mismatch") ])
    verify(missed, model_id: "m", checks: [ check("net_contents", "pass") ])

    result = EvalCorpus::Scorer.score_model(
      parents: [ parent ], mutants: [ caught, missed, unverified ], model_id: "m"
    )

    assert_equal [ caught ], result[:negatives]["BRAND"][:caught]
    assert_equal [ missed ], result[:negatives]["NET"][:missed].map { |e| e[:application] }
    assert_match(/pass/, result[:negatives]["NET"][:missed].first[:actual].first)
    assert_equal [ unverified ], result[:negatives]["FANCIFUL"][:unverified]
  end

  test "mutants_for finds only the given parents' mutants" do
    parent = application("PAR-A")
    mine = application("PAR-A-MUT-BRAND")
    application("PAR-B-MUT-BRAND")

    assert_equal [ mine ], EvalCorpus::Scorer.mutants_for([ parent ])
  end

  test "model_ids lists every model with verifications across the set" do
    app = application("POS-M")
    verify(app, model_id: "model-b", checks: [ check("brand_name", "pass") ])
    verify(app, model_id: "model-a", checks: [ check("brand_name", "pass") ])

    assert_equal %w[model-a model-b], EvalCorpus::Scorer.model_ids([ app ])
  end

  test "stratified_sample allocates proportionally and deterministically" do
    wine = 6.times.map { |i| application("W-#{i}", beverage_type: "wine") }
    malt = 3.times.map { |i| application("M-#{i}", beverage_type: "malt") }
    spirits = [ application("S-0", beverage_type: "spirits") ]
    all = (wine + malt + spirits).shuffle

    sample = EvalCorpus::Scorer.stratified_sample(all, 5)
    again = EvalCorpus::Scorer.stratified_sample(all.shuffle, 5)

    assert_equal 5, sample.size
    assert_equal sample.map(&:serial_number), again.map(&:serial_number), "deterministic regardless of input order"
    assert_equal 3, sample.count { |a| a.beverage_type == "wine" }
    by_type = sample.group_by(&:beverage_type)
    assert_equal %w[W-0 W-1 W-2], by_type["wine"].map(&:serial_number), "serial order within a type"
    assert_operator by_type.fetch("malt", []).size, :>=, 1

    assert_equal all.size, EvalCorpus::Scorer.stratified_sample(all, nil).size, "no limit returns everything"
  end
end
