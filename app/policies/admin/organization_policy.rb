class Admin::OrganizationPolicy < Admin::ApplicationPolicy
  class Scope < Admin::ApplicationPolicy::Scope
    def resolve
      scope.all
    end
  end

  has_association :memberships
  has_association :users

  def avo_index?
    rubygems_org_admin?
  end

  def avo_show?
    rubygems_org_admin?
  end

  def act_on?
    rubygems_org_admin?
  end
end
