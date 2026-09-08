# frozen_string_literal: true

require "test_helper"

class Certification::ShipPayoutTest < ActiveSupport::TestCase
  setup do
    @owner = create_user(slack_id: "U_PAYOUT_OWNER", display_name: "payoutowner")
    @reviewer = create_user(slack_id: "U_PAYOUT_REVIEWER", display_name: "payoutreviewer")

    @project = Project.create!(
      title: "Payout Project",
      description: "A project used to test the dynamic payout system",
      ship_status: "submitted"
    )
    @project.memberships.create!(user: @owner, role: :owner)
  end

  test "base_rate_for returns the category rate, falling back to the default for unknown or nil types" do
    assert_equal 0.75, Certification::Ship.base_rate_for("Web App")
    assert_equal 0.75, Certification::Ship.base_rate_for("Chat Bot")
    assert_equal 1.25, Certification::Ship.base_rate_for("CLI")
    assert_equal 1.875, Certification::Ship.base_rate_for("Minecraft Mods")
    assert_equal Certification::Ship::DEFAULT_BASE_RATE, Certification::Ship.base_rate_for(nil)
    assert_equal Certification::Ship::DEFAULT_BASE_RATE, Certification::Ship.base_rate_for("Not A Category")
  end

  test "daily_rank_multiplier rewards the top three daily reviewers by decided count" do
    reviewer_a = create_user(slack_id: "U_RANK_A", display_name: "rank_a")
    reviewer_b = create_user(slack_id: "U_RANK_B", display_name: "rank_b")
    reviewer_c = create_user(slack_id: "U_RANK_C", display_name: "rank_c")
    reviewer_d = create_user(slack_id: "U_RANK_D", display_name: "rank_d")
    reviewer_e = create_user(slack_id: "U_RANK_E", display_name: "rank_e")

    decide_ships!(reviewer_a, 3)
    decide_ships!(reviewer_b, 2)
    decide_ships!(reviewer_c, 1)
    decide_ships!(reviewer_d, 1)

    assert_equal 1.75, Certification::Ship.daily_rank_multiplier(reviewer_a.id)
    assert_equal 1.5, Certification::Ship.daily_rank_multiplier(reviewer_b.id)
    assert_equal 1.25, Certification::Ship.daily_rank_multiplier(reviewer_c.id)
    assert_equal 1.0, Certification::Ship.daily_rank_multiplier(reviewer_d.id)
    assert_equal 1.0, Certification::Ship.daily_rank_multiplier(reviewer_e.id)
  end

  test "daily_grind_multiplier steps up at 7 and 15 prior reviews today" do
    assert_equal 1.0, Certification::Ship.daily_grind_multiplier(0)
    assert_equal 1.0, Certification::Ship.daily_grind_multiplier(6)
    assert_equal 1.2, Certification::Ship.daily_grind_multiplier(7)
    assert_equal 1.2, Certification::Ship.daily_grind_multiplier(14)
    assert_equal 1.3, Certification::Ship.daily_grind_multiplier(15)
    assert_equal 1.3, Certification::Ship.daily_grind_multiplier(30)
  end

  test "old_project_multiplier steps up after 24 and 96 hours pending" do
    assert_equal 1.0, Certification::Ship.old_project_multiplier(10)
    assert_equal 1.2, Certification::Ship.old_project_multiplier(25)
    assert_equal 1.2, Certification::Ship.old_project_multiplier(96)
    assert_equal 1.5, Certification::Ship.old_project_multiplier(97)
  end

  test "queue_bonus_multiplier only discounts fresh reviews when the stale backlog is large" do
    assert_equal 1.0, Certification::Ship.queue_bonus_multiplier(1)
    assert_equal 1.0, Certification::Ship.queue_bonus_multiplier(25)

    11.times { |i| create_stale_pending_ship!("Stale #{i}") }

    assert_equal Certification::Ship::QUEUE_BONUS_MULTIPLIER, Certification::Ship.queue_bonus_multiplier(1)
    # Only applies to fresh (<=24h) reviews - an already-stale one isn't discounted further.
    assert_equal 1.0, Certification::Ship.queue_bonus_multiplier(25)
  end

  test "assign_stardust_earned multiplies base rate by every active factor and adds bonus_stardust on top" do
    @project.update!(project_type: "CLI")
    review = @project.ship_reviews.create!(status: :pending)

    review.reviewer = @reviewer
    review.status = :approved
    review.bonus_stardust = 2
    review.save!

    # Reviewer's first decided review today: rank/grind multipliers are all 1x,
    # first-review bonus is 1.5x, and the project is brand new (no old-project
    # or queue bonus).
    expected = (1.25 * 1.5) + 2
    assert_in_delta expected, review.reload.stardust_earned, 0.001
  end

  test "assign_stardust_earned does not apply the first-review bonus on a reviewer's second review today" do
    decide_ships!(@reviewer, 1)

    review = @project.ship_reviews.create!(status: :pending)
    review.reviewer = @reviewer
    review.status = :approved
    review.save!

    # No first-review bonus, but the reviewer is now the sole (and therefore
    # top) daily reviewer, so the rank bonus applies instead.
    expected = Certification::Ship::DEFAULT_BASE_RATE * Certification::Ship::DAILY_RANK_MULTIPLIERS.first
    assert_in_delta expected, review.reload.stardust_earned, 0.001
  end

  private

  def decide_ships!(reviewer, count, status: :approved)
    count.times do |i|
      project = Project.create!(
        title: "Rank Ship #{reviewer.id}-#{i}",
        description: "d",
        ship_status: "submitted"
      )
      project.memberships.create!(user: @owner, role: :owner)
      project.ship_reviews.create!(status: status, reviewer: reviewer)
    end
  end

  def create_stale_pending_ship!(title)
    project = Project.create!(title: title, description: "d", ship_status: "submitted")
    project.memberships.create!(user: @owner, role: :owner)
    review = project.ship_reviews.create!(status: :pending)
    review.update_column(:created_at, 2.days.ago)
  end
end
