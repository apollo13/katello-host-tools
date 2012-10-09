#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.
require "util/model_util"

class RepoDisablementValidator < ActiveModel::Validator
  def validate(record)
    if record.redhat? && record.enabled_changed? && (!record.enabled?) && record.promoted?
      record.errors[:base] << N_("Repository cannot be disabled since it has already been promoted.")
    end
  end
end


class Repository < ActiveRecord::Base
  include Glue::Pulp::Repo if AppConfig.use_pulp
  include Glue if AppConfig.use_cp || AppConfig.use_pulp
  include Glue::ElasticSearch::Repository if AppConfig.use_elasticsearch
  include Authorization::Repository
  include AsyncOrchestration
  include Rails.application.routes.url_helpers #required for GPG key url generation
  include Katello::LabelFromName

  before_save :refresh_content

  belongs_to :environment_product, :inverse_of => :repositories
  belongs_to :gpg_key, :inverse_of => :repositories
  belongs_to :library_instance, :class_name=>"Repository"
  has_and_belongs_to_many :changesets
  
  validates :environment_product, :presence => true
  validates :pulp_id, :presence => true, :uniqueness => true
  validates :name, :presence => true
  #validates :content_id, :presence => true #add back after fixing add_repo orchestration
  validates :label, :presence => true,:katello_label_format => true
  validates :enabled, :repo_disablement => true, :on => [:update]

  default_scope :order => 'name ASC'
  scope :enabled, where(:enabled => true)

  def product
    self.environment_product.product
  end

  def environment
    self.environment_product.environment
  end

  def organization
    self.environment.organization
  end

  def self.in_environment(env)
    joins(:environment_product).where(:environment_products => { :environment_id => env })
  end

  def self.in_product(product)
    joins(:environment_product).where("environment_products.product_id" => product.id)
  end

  def other_repos_with_same_product_and_content
    list = Repository.in_product(Product.find(self.product.id)).where(:content_id=>self.content_id).all
    list.delete(self)
    list
  end

  def other_repos_with_same_content
    list = Repository.where(:content_id=>self.content_id).all
    list.delete(self)
    list
  end

  def environment_id
    self.environment.id
  end

  def yum_gpg_key_url
    # if the repo has a gpg key return a url to access it
    if (self.gpg_key && self.gpg_key.content.present?)
      host = AppConfig.host
      host += ":" + AppConfig.port.to_s unless AppConfig.port.blank? || AppConfig.port.to_s == "443"
      gpg_key_content_api_repository_url(self, :host => host + ENV['RAILS_RELATIVE_URL_ROOT'].to_s, :protocol => 'https')
    end
  end

  def redhat?
    product.redhat?
  end

  def custom?
    !(redhat?)
  end

  def has_filters?
    return false unless environment.library?
    filters.count > 0 || product.filters.count > 0
  end

  def sync_complete task
    notify = task.parameters.try(:[], :options).try(:[], :notify)
    user = task.user
    if task.state == TaskStatus::Status::FINISHED
      if user && notify
        Notify.success _("Repository '%s' finished syncing successfully.") % [self.name],
                       :user => user, :organization => self.organization
      end
    elsif task.state == 'error'
      details = if task.progress.error_details.present?
                  task.progress.error_details
                else
                  task.result[:errors].flatten
                end

      Rails.logger.error("*** Sync error: " +  details.to_json)
      if user && notify
        Notify.error _("There were errors syncing repository '%s'. See notices page for more details.") % self.name,
                     :details => details.map(&:chomp).join("\n"), :user => user, :organization => self.organization
      end
    end
  end

  def clones
    lib_id = self.library_instance_id || self.id
    Repository.in_environment(self.environment.successors).where(:library_instance_id=>lib_id)
  end

  #is the repo cloned in the specified environment
  def is_cloned_in? env
    lib_id = self.library_instance_id ? self.library_instance_id : self.id
    self.get_clone(env) != nil
  end

  def promoted?
    if self.environment.library?
      Repository.where(:library_instance_id=>self.id).count > 0
    else
      true
    end
  end

  def get_clone env
    lib_id = self.library_instance_id || self.id
    Repository.in_environment(env).where(:library_instance_id=>lib_id).first
  end

  def gpg_key_name=(name)
    if name.blank?
      self.gpg_key = nil
    else
      self.gpg_key = GpgKey.readable(organization).find_by_name!(name)
    end
  end

  def as_json(*args)
    ret = super
    ret["gpg_key_name"] = gpg_key ? gpg_key.name : ""
    ret["package_count"] = package_count rescue nil
    ret["last_sync"] = last_sync rescue nil
    ret
  end

  # returns other instances of this repo with the same library
  # equivalent of repo
  def environmental_instances
    if self.environment.library?
      repo = self
    else
      repo = self.library_instance
    end
    Repository.where("library_instance_id=%s or repositories.id=%s"  % [repo.id, repo.id] )
  end

  #Filters that should be applied for content coming into this repository.
  def applicable_filters
    previous = self.environmental_instances.in_environment(self.environment.prior).first
    if previous && previous.environment.prior.nil?  #if previous exists and is library
      previous.filters + self.product.filters
    else
      []
    end
  end

  private

  def refresh_content
    return if self.new_record?  #don't try to refresh on create

    #if the gpg key was enabled
    #we only update the content if the content is actually not set properly
    #this means we don't recreate the environment for the same repo in 
    #each environment.   We do the same for it being disabled, we check
    #to make sure it is not enabled in the contnet before refreshing
    if (self.gpg_key_id_was == nil && self.gpg_key_id != nil) 
        self.product.refresh_content(self) if self.content.gpgUrl == ''
    elsif (self.gpg_key_id_was != nil && self.gpg_key_id == nil)
        self.product.refresh_content(self) if self.content.gpgUrl != ''
    end
  end
end
