require "test_helper"

class Api::V1::OwnersControllerTest < ActionController::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  def self.should_respond_to(format)
    should "route GET show with #{format.to_s.upcase}" do
      route = { controller: "api/v1/owners",
                action: "show",
                rubygem_id: "rails",
                format: format.to_s }

      assert_recognizes(route, "/api/v1/gems/rails/owners.#{format}")
    end

    context "on GET to show with #{format.to_s.upcase}" do
      setup do
        @rubygem = create(:rubygem)
        @user = create(:user)
        @other_user = create(:user)
        create(:ownership, rubygem: @rubygem, user: @user)

        get :show, params: { rubygem_id: @rubygem.slug }, format: format
      end

      should "return an array" do
        response = yield(@response.body)

        assert_kind_of Array, response
      end

      should "return correct owner handle" do
        assert_equal @user.handle, yield(@response.body)[0]["handle"]
      end

      should "not return other owner handle" do
        assert yield(@response.body).pluck("handle").exclude?(@other_user.handle)
      end
    end
  end

  should_respond_to :json do |body|
    JSON.parse body
  end

  should_respond_to :yaml do |body|
    YAML.safe_load body
  end

  context "on GET to owner gems with handle" do
    setup do
      @user = create(:user)
      get :gems, params: { handle: @user.handle }, format: :json
    end

    should respond_with :success
  end

  context "on GET to owner gems with nonexistent handle" do
    setup do
      get :gems, params: { handle: "imaginary_handler" }, format: :json
    end

    should "return plaintext with error message" do
      assert_equal("Owner could not be found.", @response.body)
    end

    should respond_with :not_found
  end

  context "on GET to owner gems with id" do
    setup do
      @user = create(:user)
      rubygem = create(:rubygem, owners: [@user])
      version = create(:version, rubygem: rubygem)
      rubygem2 = create(:rubygem, owners: [@user])
      rubygem3 = create(:rubygem, owners: [@user])
      version2 = create(:version, rubygem: rubygem2)
      create(:dependency, version: version, rubygem: rubygem2, requirements: ">= 0", scope: "runtime")
      create(:dependency, version: version, rubygem: rubygem3, requirements: ">= 0", scope: "development")
      create(:dependency, version: version2, rubygem: rubygem3, requirements: ">= 0", scope: "runtime")
      get :gems, params: { handle: @user.id }, format: :json
    end

    should respond_with :success
  end

  context "on GET to owner gems with nonexistent id" do
    setup do
      @user = create(:user)
      get :gems, params: { handle: -9999 }, format: :json
    end

    should "return plain text with error message" do
      assert_equal("Owner could not be found.", @response.body)
    end

    should respond_with :not_found
  end

  should "route POST /api/v1/gems/rubygem/owners.json" do
    route = { controller: "api/v1/owners",
              action: "create",
              rubygem_id: "rails",
              format: "json" }

    assert_recognizes(route, path: "/api/v1/gems/rails/owners.json", method: :post)
  end

  should "route POST /api/v1/gems/rubygem/owners.yaml" do
    route = { controller: "api/v1/owners",
              action: "create",
              rubygem_id: "rails",
              format: "yaml" }

    assert_recognizes(route, path: "/api/v1/gems/rails/owners.yaml", method: :post)
  end

  should "route POST /api/v1/gems/rubygem/owners" do
    route = { controller: "api/v1/owners",
              action: "create",
              rubygem_id: "rails" }

    assert_recognizes(route, path: "/api/v1/gems/rails/owners", method: :post)
  end

  context "on POST to owner gem" do
    context "with add owner api key scope" do
      setup do
        @rubygem = create(:rubygem)
        @user = create(:user)
        @second_user = create(:user)
        @third_user = create(:user)
        @ownership = create(:ownership, rubygem: @rubygem, user: @user)
        @api_key = create(:api_key, key: "12334", scopes: %i[add_owner], owner: @user)
        @request.env["HTTP_AUTHORIZATION"] = "12334"
      end

      context "when mfa for UI and API is enabled" do
        setup do
          @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_api)
        end

        context "array of emails" do
          setup do
            @third_user = create(:user)
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
            post :create, params: { rubygem_id: @rubygem.slug, email: [@second_user.email, @third_user.email] }
          end

          should respond_with :bad_request
          should "fail to add new owner" do
            refute_includes @rubygem.owners_including_unconfirmed, @second_user
            refute_includes @rubygem.owners_including_unconfirmed, @third_user
          end
        end

        context "adding other user as gem owner without OTP" do
          setup do
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :unauthorized

          should "fail to add new owner" do
            refute_includes @rubygem.owners_including_unconfirmed, @second_user
          end
          should "return body that starts with MFA enabled message" do
            assert @response.body.start_with?("You have enabled multifactor authentication")
          end
        end

        context "adding other user as gem owner with incorrect OTP" do
          setup do
            @request.env["HTTP_OTP"] = (ROTP::TOTP.new(@user.totp_seed).now.to_i.succ % 1_000_000).to_s
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :unauthorized

          should "fail to add new owner" do
            refute_includes @rubygem.owners_including_unconfirmed, @second_user
          end
        end

        context "adding other user as gem owner with correct OTP" do
          setup do
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :success

          should "succeed to add new owner" do
            assert_includes @rubygem.owners_including_unconfirmed, @second_user
          end
        end
      end

      context "when mfa for UI only is enabled" do
        setup do
          @user.enable_totp!(ROTP::Base32.random_base32, :ui_only)
        end

        context "api key has mfa enabled" do
          setup do
            @api_key.mfa = true
            @api_key.save!
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end
          should respond_with :unauthorized
        end

        context "api key does not have mfa enabled" do
          setup do
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end
          should respond_with :success
        end
      end

      context "when mfa for UI and API is disabled" do
        context "add user with email" do
          setup do
            perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
              post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
            end
          end

          should "add second user as unconfrimed owner" do
            assert_includes @rubygem.owners_including_unconfirmed, @second_user
            assert_equal "#{@second_user.handle} was added as an unconfirmed owner. " \
                         "Ownership access will be enabled after the user clicks on the confirmation mail sent to their email.", @response.body
          end

          should "send confirmation mail to second user" do
            assert_equal "Please confirm the ownership of the #{@rubygem.name} gem on RubyGems.org", last_email.subject
            assert_equal [@second_user.email], last_email.to
          end
        end

        context "add user with handler" do
          setup do
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.handle }
          end

          should "add other user as gem owner" do
            assert_includes @rubygem.owners_including_unconfirmed, @second_user
          end
        end
      end

      context "user is not found" do
        setup do
          post :create, params: { rubygem_id: @rubygem.slug, email: "doesnot@exist.com" }
        end

        should respond_with :not_found
      end

      context "owner already exists" do
        setup do
          post :create, params: { rubygem_id: @rubygem.slug, email: @user.email }
        end

        should respond_with :unprocessable_content

        should "respond with error message" do
          assert_equal "User is already an owner of this gem", @response.body
        end
      end

      context "owner has already been invited" do
        setup do
          post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
        end

        should respond_with :unprocessable_content

        should "respond with error message" do
          assert_equal "User is already invited to this gem", @response.body
        end
      end

      context "when mfa is required by gem" do
        setup do
          metadata = { "rubygems_mfa_required" => "true" }
          create(:version, rubygem: @rubygem, number: "1.0.0", metadata: metadata)
        end

        context "api user has enabled mfa" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_api)
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
          end

          should "add other user as gem owner" do
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }

            assert_includes @rubygem.owners_including_unconfirmed, @second_user
          end
        end

        context "api user has not enabled mfa" do
          setup do
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :forbidden

          should "refuse to add other user as gem owner" do
            refute_includes @rubygem.owners_including_unconfirmed, @second_user
          end
        end
      end

      context "when mfa is required by yanked gem" do
        setup do
          metadata = { "rubygems_mfa_required" => "true" }
          create(:version, rubygem: @rubygem, number: "1.0.0", indexed: false, metadata: metadata)

          post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
        end

        should respond_with :success

        should "add other user as gem owner" do
          assert_includes @rubygem.owners_including_unconfirmed, @second_user
        end
      end

      context "with api key gem scoped" do
        context "to another gem" do
          setup do
            another_rubygem_ownership = create(:ownership, user: @user, rubygem: create(:rubygem, name: "test"))

            @api_key.update(ownership: another_rubygem_ownership)
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :forbidden

          should "not add other user as gem owner" do
            refute_includes @rubygem.owners, @second_user
          end
        end

        context "to the same gem" do
          setup do
            @api_key.update(rubygem_id: @rubygem.id)
            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :success

          should "adds other user as gem owner" do
            assert_includes @rubygem.owners_including_unconfirmed, @second_user
          end
        end

        context "to a gem with ownership removed" do
          setup do
            @api_key.update(ownership: @ownership)
            @ownership.destroy!

            post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :forbidden

          should "#render_soft_deleted_api_key and display an error" do
            assert_equal "An invalid API key cannot be used. Please delete it and create a new one.", @response.body
          end
        end
      end

      context "with a soft deleted api key" do
        setup do
          @api_key.soft_delete!

          post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
        end

        should respond_with :forbidden

        should "#render_soft_deleted_api_key and display an error" do
          assert_equal "An invalid API key cannot be used. Please delete it and create a new one.", @response.body
        end
      end

      context "when mfa is required" do
        setup do
          User.any_instance.stubs(:mfa_required?).returns true
          @emails = [@second_user.email, "doesnotexist@example.com", @user.email]
        end

        context "by user with mfa disabled" do
          should "block adding the owner" do
            @emails.each do |email|
              post :create, params: { rubygem_id: @rubygem.slug, email: email }

              assert_equal 403, @response.status
              mfa_error = I18n.t("multifactor_auths.api.mfa_required_not_yet_enabled").chomp

              assert_includes @response.body, mfa_error
            end
          end
        end

        context "by user on `ui_only` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_only)
          end

          should "block adding the owner" do
            @emails.each do |email|
              post :create, params: { rubygem_id: @rubygem.slug, email: email }

              assert_equal 403, @response.status
              mfa_error = I18n.t("multifactor_auths.api.mfa_required_weak_level_enabled").chomp

              assert_includes @response.body, mfa_error
            end
          end
        end

        context "by user on `ui_and_gem_signin` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_gem_signin)
          end

          should "not show error message" do
            @emails.each do |email|
              post :create, params: { rubygem_id: @rubygem.slug, email: email }

              refute_includes @response.body, "For protection of your account and your gems"
            end
          end
        end

        context "by user on `ui_and_api` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_api)
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
          end

          should "not show error message" do
            @emails.each do |email|
              post :create, params: { rubygem_id: @rubygem.slug, email: email }

              refute_includes @response.body, "For protection of your account and your gems"
            end
          end
        end
      end

      context "when mfa is recommended" do
        setup do
          User.any_instance.stubs(:mfa_recommended?).returns true
          @emails = [@second_user.email, "doesnotexist@example.com", @user.email]
        end

        context "by user with mfa disabled" do
          should "include mfa setup warning" do
            @emails.each do |email|
              post :create, params: { rubygem_id: @rubygem.slug, email: email }
              mfa_warning = "\n\n#{I18n.t('multifactor_auths.api.mfa_recommended_not_yet_enabled')}".chomp

              assert_includes @response.body, mfa_warning
            end
          end
        end

        context "by user on `ui_only` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_only)
          end

          should "include change mfa level warning" do
            @emails.each do |email|
              post :create, params: { rubygem_id: @rubygem.slug, email: email }
              mfa_warning = "\n\n#{I18n.t('multifactor_auths.api.mfa_recommended_weak_level_enabled')}".chomp

              assert_includes @response.body, mfa_warning
            end
          end
        end

        context "by user on `ui_and_gem_signin` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_gem_signin)
          end

          should "not include MFA warnings" do
            @emails.each do |email|
              post :create, params: { rubygem_id: @rubygem.slug, email: email }

              refute_includes @response.body, I18n.t("multifactor_auths.api.mfa_recommended_not_yet_enabled").chomp
              refute_includes @response.body, I18n.t("multifactor_auths.api.mfa_recommended_weak_level_enabled").chomp
            end
          end
        end

        context "by user on `ui_and_api` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_api)
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
          end

          should "not include mfa warnings" do
            @emails.each do |email|
              post :create, params: { rubygem_id: @rubygem.slug, email: email }

              refute_includes @response.body, I18n.t("multifactor_auths.api.mfa_recommended_not_yet_enabled").chomp
              refute_includes @response.body, I18n.t("multifactor_auths.api.mfa_recommended_weak_level_enabled").chomp
            end
          end
        end
      end

      context "when not supplying a role" do
        should "set a default role" do
          post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.display_id }

          assert_equal 200, @response.status
          assert_predicate Ownership.find_by(user: @second_user, rubygem: @rubygem), :owner?
        end
      end

      context "given a role" do
        should "set the role for the given user" do
          post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.display_id, role: :maintainer }

          assert_equal 200, @response.status
          assert_predicate Ownership.find_by(user: @second_user, rubygem: @rubygem), :maintainer?
        end
      end

      context "when given an invalid role" do
        should "raise an error" do
          post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.display_id, role: :invalid }

          assert_equal 422, @response.status
          assert_equal "Role is not included in the list", @response.body
        end

        should "not create the ownership" do
          post :create, params: { rubygem_id: @rubygem.slug, email: @second_user.email, role: :invalid }

          assert_nil @rubygem.ownerships.find_by(user: @second_user)
        end
      end
    end

    context "without add owner api key scope" do
      setup do
        api_key = create(:api_key, key: "12323")
        rubygem = create(:rubygem, owners: [api_key.user])

        @request.env["HTTP_AUTHORIZATION"] = "12323"
        post :create, params: { rubygem_id: rubygem.slug, email: "some@email.com" }
      end

      should respond_with :forbidden

      should "return body with denied access message" do
        assert_equal "This API key cannot perform the specified action on this gem.", @response.body
      end
    end
  end

  should "route DELETE /api/v1/gems/gemname/owners.json" do
    route = { controller: "api/v1/owners",
              action: "destroy",
              rubygem_id: "rails",
              format: "json" }

    assert_recognizes(route, path: "/api/v1/gems/rails/owners.json", method: :delete)
  end

  should "route DELETE /api/v1/gems/gemname/owners.yaml" do
    route = { controller: "api/v1/owners",
              action: "destroy",
              rubygem_id: "rails",
              format: "yaml" }

    assert_recognizes(route, path: "/api/v1/gems/rails/owners.yaml", method: :delete)
  end

  should "route DELETE /api/v1/gems/gemname/owners" do
    route = { controller: "api/v1/owners",
              action: "destroy",
              rubygem_id: "rails" }

    assert_recognizes(route, path: "/api/v1/gems/rails/owners", method: :delete)
  end

  context "on DELETE to owner gem" do
    context "with remove owner api key scope" do
      setup do
        @rubygem = create(:rubygem)
        @user = create(:user)
        @second_user = create(:user)
        @ownership = create(:ownership, rubygem: @rubygem, user: @user)
        @ownership = create(:ownership, rubygem: @rubygem, user: @second_user)

        @api_key = create(:api_key, key: "12223", scopes: %i[remove_owner], owner: @user)
        @request.env["HTTP_AUTHORIZATION"] = "12223"
      end

      context "when mfa for UI and API is enabled" do
        setup do
          @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_api)
        end

        context "removing gem owner without OTP" do
          setup do
            delete :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :unauthorized

          should "fail to remove gem owner" do
            assert_includes @rubygem.owners, @second_user
          end
          should "return body that starts with MFA enabled message" do
            assert @response.body.start_with?("You have enabled multifactor authentication")
          end
        end

        context "removing gem owner with incorrect OTP" do
          setup do
            @request.env["HTTP_OTP"] = (ROTP::TOTP.new(@user.totp_seed).now.to_i.succ % 1_000_000).to_s
            delete :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :unauthorized

          should "fail to remove gem owner" do
            assert_includes @rubygem.owners, @second_user
          end
        end

        context "removing gem owner with correct OTP" do
          setup do
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
            delete :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :success

          should "succeed to remove gem owner" do
            refute_includes @rubygem.owners, @second_user
          end
        end
      end

      context "when mfa for UI and API is disabled" do
        context "user is not the only confirmed owner" do
          setup do
            perform_enqueued_jobs only: ActionMailer::MailDeliveryJob do
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
            end
          end

          should "remove user as gem owner" do
            refute_includes @rubygem.owners, @second_user
            assert_equal "Owner removed successfully.", @response.body
          end

          should "send email notification to user being removed" do
            assert_equal "You were removed as an owner from the #{@rubygem.name} gem", last_email.subject
            assert_equal [@second_user.email], last_email.to
          end
        end

        context "user is the only confirmed owner" do
          setup do
            @ownership.destroy
            delete :destroy, params: { rubygem_id: @rubygem.slug, email: @user.email }
          end

          should "not remove last gem owner" do
            assert_includes @rubygem.owners, @user
            assert_equal "Unable to remove owner.", @response.body
          end
        end
      end

      context "when mfa is required by gem version" do
        setup do
          metadata = { "rubygems_mfa_required" => "true" }
          create(:version, rubygem: @rubygem, number: "1.0.0", metadata: metadata)
        end

        context "api user hasi not enabled mfa" do
          setup do
            delete :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :forbidden

          should "fail to remove gem owner" do
            assert_includes @rubygem.owners, @second_user
          end
        end

        context "api user has enabled mfa" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_api)
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
          end

          context "on delete to remove gem owner with correct OTP" do
            setup do
              @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
            end

            should respond_with :success

            should "succeed to remove gem owner" do
              refute_includes @rubygem.owners, @second_user
            end
          end
        end
      end

      context "with api key gem scoped" do
        context "to another gem" do
          setup do
            another_rubygem_ownership = create(:ownership, user: @user, rubygem: create(:rubygem, name: "test"))

            @api_key.update(ownership: another_rubygem_ownership)
            post :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :forbidden
          should "not remove other user as gem owner" do
            assert_includes @rubygem.owners, @second_user
            assert_equal "This API key cannot perform the specified action on this gem.", @response.body
          end
        end

        context "to the same gem" do
          setup do
            @api_key.update(rubygem_id: @rubygem.id)
            post :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :success

          should "removes other user as gem owner" do
            refute_includes @rubygem.owners, @second_user
          end
        end

        context "to a gem with ownership removed" do
          setup do
            @api_key.update(ownership: @ownership)
            @ownership.destroy!

            post :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
          end

          should respond_with :forbidden

          should "#render_soft_deleted_api_key and display an error" do
            assert_equal "An invalid API key cannot be used. Please delete it and create a new one.", @response.body
          end
        end
      end

      context "with a soft deleted api key" do
        setup do
          @api_key.soft_delete!

          post :destroy, params: { rubygem_id: @rubygem.slug, email: @second_user.email }
        end

        should respond_with :forbidden

        should "#render_soft_deleted_api_key and display an error" do
          assert_equal "An invalid API key cannot be used. Please delete it and create a new one.", @response.body
        end
      end

      context "when mfa is required" do
        setup do
          User.any_instance.stubs(:mfa_required?).returns true
          @emails = [@second_user.email, "doesnotexist@example.com", @user.email, "no@permission.com"]
        end

        context "by user with mfa disabled" do
          should "block adding the owner" do
            @emails.each do |email|
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: email }

              assert_equal 403, response.status
              mfa_error = I18n.t("multifactor_auths.api.mfa_required_not_yet_enabled").chomp

              assert_includes @response.body, mfa_error
            end
          end
        end

        context "by user on `ui_only` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_only)
          end

          should "block adding the owner" do
            @emails.each do |email|
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: email }

              assert_equal 403, @response.status
              mfa_error = I18n.t("multifactor_auths.api.mfa_required_weak_level_enabled").chomp

              assert_includes @response.body, mfa_error
            end
          end
        end

        context "by user on `ui_and_gem_signin` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_gem_signin)
          end

          should "not show error message" do
            @emails.each do |email|
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: email }

              refute_includes @response.body, "For protection of your account and your gems"
            end
          end
        end

        context "by user on `ui_and_api` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_api)
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
          end

          should "not show error message" do
            @emails.each do |email|
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: email }

              refute_includes @response.body, "For protection of your account and your gems"
            end
          end
        end
      end

      context "when mfa is recommended" do
        setup do
          User.any_instance.stubs(:mfa_recommended?).returns true
          @emails = [@second_user.email, "doesnotexist@example.com", @user.email, "nopermission@example.com"]
        end

        context "by user with mfa disabled" do
          should "include mfa setup warning" do
            @emails.each do |email|
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: email }
              mfa_warning = "\n\n#{I18n.t('multifactor_auths.api.mfa_recommended_not_yet_enabled')}".chomp

              assert_includes @response.body, mfa_warning
            end
          end
        end

        context "by user on `ui_only` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_only)
          end

          should "include change mfa level warning" do
            @emails.each do |email|
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: email }
              mfa_warning = "\n\n#{I18n.t('multifactor_auths.api.mfa_recommended_weak_level_enabled')}".chomp

              assert_includes @response.body, mfa_warning
            end
          end
        end

        context "by user on `ui_and_gem_signin` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_gem_signin)
          end

          should "not include mfa warnings" do
            @emails.each do |email|
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: email }

              refute_includes @response.body, I18n.t("multifactor_auths.api.mfa_recommended_not_yet_enabled").chomp
              refute_includes @response.body, I18n.t("multifactor_auths.api.mfa_recommended_weak_level_enabled").chomp
            end
          end
        end

        context "by user on `ui_and_api` level" do
          setup do
            @user.enable_totp!(ROTP::Base32.random_base32, :ui_and_api)
            @request.env["HTTP_OTP"] = ROTP::TOTP.new(@user.totp_seed).now
          end

          should "not include mfa warnings" do
            @emails.each do |email|
              delete :destroy, params: { rubygem_id: @rubygem.slug, email: email }

              refute_includes @response.body, I18n.t("multifactor_auths.api.mfa_recommended_not_yet_enabled").chomp
              refute_includes @response.body, I18n.t("multifactor_auths.api.mfa_recommended_weak_level_enabled").chomp
            end
          end
        end
      end
    end

    context "without remove owner api key scope" do
      setup do
        api_key = create(:api_key, key: "12342")
        rubygem = create(:rubygem, owners: [api_key.user])

        @request.env["HTTP_AUTHORIZATION"] = "12342"
        delete :destroy, params: { rubygem_id: rubygem.slug, email: "some@owner.com" }
      end

      should respond_with :forbidden

      should "return body that has the denied access message" do
        assert_equal "This API key cannot perform the specified action on this gem.", @response.body
      end
    end
  end

  should "route GET /api/v1/owners/username/gems.json" do
    route = { controller: "api/v1/owners",
              action: "gems",
              handle: "example",
              format: "json" }

    assert_recognizes(route, path: "/api/v1/owners/example/gems.json", method: :get)
  end

  should "route GET /api/v1/owners/username/gems.yaml" do
    route = { controller: "api/v1/owners",
              action: "gems",
              handle: "example",
              format: "yaml" }

    assert_recognizes(route, path: "/api/v1/owners/example/gems.yaml", method: :get)
  end

  should "return plain text 404 error" do
    create(:api_key, key: "12223", scopes: %i[add_owner])
    @request.env["HTTP_AUTHORIZATION"] = "12223"
    @request.accept = "*/*"
    post :create, params: { rubygem_id: "bananas" }

    assert_equal "This rubygem could not be found.", @response.body
  end

  should "route PUT /api/v1/gems/rubygem/owners.yaml" do
    route = { controller: "api/v1/owners",
              action: "update",
              rubygem_id: "rails",
              format: "yaml" }

    assert_recognizes(route, path: "/api/v1/gems/rails/owners.yaml", method: :put)
  end

  context "on PATCH to owner gem" do
    setup do
      @owner = create(:user)
      @maintainer = create(:user)
      @rubygem = create(:rubygem, owners: [@owner])

      @api_key = create(:api_key, key: "12223", scopes: %i[update_owner], owner: @owner, rubygem: @rubygem)
      @request.env["HTTP_AUTHORIZATION"] = "12223"
    end

    should "set the maintainer to a lower access level" do
      ownership = create(:ownership, user: @maintainer, rubygem: @rubygem, role: :owner)

      patch :update, params: { rubygem_id: @rubygem.slug, email: @maintainer.email, role: :maintainer }

      assert_response :success
      assert_predicate ownership.reload, :maintainer?
      assert_enqueued_email_with OwnersMailer, :owner_updated, params: { ownership: ownership }
    end

    context "when the current user is changing their own role" do
      should "forbid changing the role" do
        patch :update, params: { rubygem_id: @rubygem.slug, email: @owner.email, role: :maintainer }

        ownership = @rubygem.ownerships.find_by(user: @owner)

        assert_response :forbidden
        assert_predicate ownership.reload, :owner?
      end
    end

    context "when the role is invalid" do
      should "return a bad request response with the error message" do
        ownership = create(:ownership, user: @maintainer, rubygem: @rubygem, role: :maintainer)

        patch :update, params: { rubygem_id: @rubygem.slug, email: @maintainer.email, role: :invalid }

        assert_response :unprocessable_entity
        assert_equal "Role is not included in the list", @response.body
        assert_predicate ownership.reload, :maintainer?
      end
    end

    context "when the owner is not found" do
      context "when the update is authorized" do
        should "return a not found response" do
          patch :update, params: { rubygem_id: @rubygem.slug, email: "notauser", role: :owner }

          assert_response :not_found
          assert_equal "Owner could not be found.", @response.body
        end
      end

      context "when the update is not authorized" do
        should "return a forbidden response" do
          @api_key = create(:api_key, key: "99999", scopes: %i[push_rubygem], owner: @owner)
          @request.env["HTTP_AUTHORIZATION"] = "99999"

          patch :update, params: { rubygem_id: @rubygem.slug, email: "notauser", role: :owner }

          assert_response :forbidden
          assert_equal "This API key cannot perform the specified action on this gem.", @response.body
        end
      end
    end
  end
end
