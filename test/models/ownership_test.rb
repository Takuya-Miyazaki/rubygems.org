require "test_helper"

class OwnershipTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  should "be valid with factory" do
    assert_predicate build(:ownership), :valid?
  end

  should belong_to :rubygem
  should have_db_index :rubygem_id
  should belong_to :user
  should belong_to :authorizer
  should have_db_index %i[user_id rubygem_id]
  should have_many(:api_key_rubygem_scopes).dependent(:destroy)

  context "by_indexed_gem_name" do
    setup do
      @ownership = create(:ownership)
      create_list(:version, 5, rubygem: @ownership.rubygem)
      @user = @ownership.user
    end

    should "return only one ownership" do
      assert_equal 1, @user.ownerships.by_indexed_gem_name.size
    end
  end

  context "by_indexed_gem_name order matters" do
    setup do
      @user = create(:user)
      @gems = %w[zork asf medium]
      @gems.each do |gem_name|
        created_gem = create(:rubygem, name: gem_name)
        create_list(:version, 3, rubygem: created_gem)
        create(:ownership, rubygem: created_gem, user: @user)
      end

      @ownerships = @user.ownerships.by_indexed_gem_name
    end

    should "ownerships should be sorted by rubygem name ascendant order" do
      assert_equal @gems.sort, (@ownerships.map { |own| own.rubygem.name })
    end
  end

  context "#safe_destroy" do
    setup do
      @rubygem       = create(:rubygem)
      @ownership_one = create(:ownership, rubygem: @rubygem)
      @ownership_two = create(:ownership, :unconfirmed, rubygem: @rubygem)
    end

    should "allow deletion of unconfirmed ownership" do
      @ownership_two.safe_destroy

      assert_equal 1, @rubygem.owners_including_unconfirmed.length
    end

    should "not allow deletion of only confirmed ownerships" do
      @ownership_two.safe_destroy

      refute @ownership_one.safe_destroy
      assert_equal 1, @rubygem.owners.length
      assert_equal @ownership_one.user, @rubygem.owners.last
    end
  end

  context "#create" do
    setup do
      @authorizer = create(:user)
      @new_owner = create(:user)
      @rubygem = create(:rubygem)
    end

    should "create unconfirmed ownership" do
      ownership = @rubygem.ownerships.create(user: @new_owner, authorizer: @authorizer)

      assert_nil ownership.confirmed_at
    end

    should "generate 20 char hex confirmation token" do
      ownership = @rubygem.ownerships.create(user: @new_owner, authorizer: @authorizer)

      assert_match(/[0-9a-f]{20}/, ownership.token)
    end

    should "not create without a user" do
      ownership = build(:ownership, user: nil)

      refute_predicate ownership, :valid?
      assert_contains ownership.errors[:user], "must exist"
    end

    should "not create without a rubygem" do
      ownership = build(:ownership, rubygem: nil)

      refute_predicate ownership, :valid?
      assert_contains ownership.errors[:rubygem], "must exist"
    end

    should "not create with a duplicate unconfirmed user and rubygem" do
      existing_ownership = create(:ownership, :unconfirmed)
      ownership = build(:ownership, user: existing_ownership.user, rubygem: existing_ownership.rubygem)

      refute_predicate ownership, :valid?
      assert_contains ownership.errors[:user_id], "is already invited to this gem"
    end

    should "not create with a duplicate confirmed user and rubygem" do
      existing_ownership = create(:ownership)
      ownership = build(:ownership, user: existing_ownership.user, rubygem: existing_ownership.rubygem)

      refute_predicate ownership, :valid?
      assert_contains ownership.errors[:user_id], "is already an owner of this gem"
    end

    should "not update to a duplicate confirmed user and rubygem" do
      existing_ownership = create(:ownership)
      ownership = create(:ownership, :unconfirmed, rubygem: existing_ownership.rubygem)
      ownership.user = existing_ownership.user

      refute_predicate ownership, :valid?
      assert_contains ownership.errors[:user_id], "is already an owner of this gem"
    end
  end

  context "#update" do
    context "when updating the role" do
      setup do
        @actor = create(:user)
        @ownership = create(:ownership, role: :owner)

        Current.user = @actor
      end

      should "record an event" do
        @ownership.update!(role: :maintainer)

        event = @ownership.rubygem.events.last
        attributes = {
          "user_agent_info" => nil,
          "owner" => @ownership.user.display_handle,
          "updated_by" => @actor.display_handle,
          "actor_gid" => @actor.to_gid,
          "owner_gid" => @ownership.user.to_gid,
          "previous_role" => "owner",
          "current_role" => "maintainer"
        }

        assert_equal "rubygem:owner:role_updated", event.tag
        assert_equal attributes, event.additional.attributes
      end

      should "enqueue the owner updated email" do
        assert_enqueued_emails 1 do
          @ownership.update!(role: :maintainer)
        end
      end
    end
  end

  context "#valid_confirmation_token?" do
    setup do
      @ownership = create(:ownership)
    end

    should "return false when email confirmation token has expired" do
      @ownership.update_attribute(:token_expires_at, 2.minutes.ago)

      refute_predicate @ownership, :valid_confirmation_token?
    end

    should "return true when email confirmation token has not expired" do
      two_minutes_in_future = 2.minutes.from_now
      @ownership.update_attribute(:token_expires_at, two_minutes_in_future)

      assert_predicate @ownership, :valid_confirmation_token?
    end
  end

  context "#create_confirmed" do
    setup do
      rubygem = create(:rubygem)
      user = create(:user)
      Ownership.create_confirmed(rubygem, user, user)
    end

    should "create confirmed ownership" do
      ownership = Ownership.last

      assert_nil ownership.token
      assert_predicate ownership, :confirmed?
    end
  end

  context "#find_by_owner_handle" do
    setup do
      @rubygem = create(:rubygem)
      @user = create(:user)
      @ownership = create(:ownership, rubygem: @rubygem, user: @user)
    end

    should "find owner by matching handle/id" do
      assert_equal @ownership, @rubygem.ownerships.find_by_owner_handle(@user.handle)
      assert_equal @ownership, @rubygem.ownerships.find_by_owner_handle(@user)
    end

    should "return nil" do
      assert_nil @rubygem.ownerships.find_by_owner_handle("wronguser")
    end
  end

  context "#confirm!" do
    setup do
      @rubygem = create(:rubygem)
      user = create(:user)
      @ownership = create(:ownership, :unconfirmed, rubygem: @rubygem, user: user)
    end

    context "ownership is unconfirmed" do
      should "update token to nil" do
        assert_changes -> { @ownership.token }, to: nil do
          @ownership.confirm!
        end
      end

      should "update confirmed_at" do
        freeze_time do
          @ownership.confirm!

          assert_equal Time.current, @ownership.confirmed_at
        end
        assert_includes @rubygem.ownerships, @ownership
      end
    end

    context "ownership is confirmed" do
      should "not update if confirmed" do
        @ownership.confirm!
        assert_no_changes -> { @ownership.confirmed_at } do
          @ownership.confirm!
        end
        assert_no_changes -> { @ownership.token } do
          @ownership.confirm!
        end
      end
    end
  end

  context "#confirmed?" do
    setup do
      rubygem = create(:rubygem)
      user = create(:user)
      @ownership = create(:ownership, :unconfirmed, rubygem: rubygem, user: user)
    end

    should "return false if not confirmed" do
      refute_predicate @ownership, :confirmed?
    end

    should "return true if confirmed" do
      @ownership.confirm!

      assert_predicate @ownership, :confirmed?
    end
  end

  context "#unconfirmed?" do
    setup do
      rubygem = create(:rubygem)
      user = create(:user)
      @ownership = create(:ownership, :unconfirmed, rubygem: rubygem, user: user)
    end

    should "return false if not confirmed" do
      assert_predicate @ownership, :unconfirmed?
    end

    should "return true if confirmed" do
      @ownership.confirm!

      refute_predicate @ownership, :unconfirmed?
    end
  end

  context "#role" do
    setup do
      @ownership = create(:ownership)
    end

    should "set a default role" do
      assert_predicate @ownership, :owner?
    end
  end

  context "#user_with_minimum_role" do
    setup do
      @user = create(:user)
      @ownership = create(:ownership, user: @user, role: :owner)
    end

    should "return the ownerships with a role less than or equal to the given role" do
      assert_includes Ownership.user_with_minimum_role(@user, :owner), @ownership
      assert_includes Ownership.user_with_minimum_role(@user, :maintainer), @ownership
    end
  end
end
