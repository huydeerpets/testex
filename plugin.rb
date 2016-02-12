# name: discourse-expired
# about: Add a expired button to topic on Discourse
# version: 0.1
# authors: Sam Saffron

PLUGIN_NAME = "discourse_expired".freeze

register_asset 'stylesheets/solutions.scss'

after_initialize do

  module ::DiscourseExpired
    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DiscourseExpired
    end
  end

  require_dependency "application_controller"
  class DiscourseExpired::AnswerController < ::ApplicationController
    def expire

      limit_expires

      post = Post.find(params[:id].to_i)

      guardian.ensure_can_expire_answer!(post.topic)

      expired_id = post.topic.custom_fields["expired_topic_post_id"].to_i
      if expired_id > 0
        if p2 = Post.find_by(id: expired_id)
          p2.custom_fields["is_expired_topic"] = nil
          p2.save!
        end
      end

      post.custom_fields["is_expired_topic"] = "true"
      post.topic.custom_fields["expired_topic_post_id"] = post.id
      post.topic.save!
      post.save!

      unless current_user.id == post.user_id

        Notification.create!(notification_type: Notification.types[:custom],
                           user_id: post.user_id,
                           topic_id: post.topic_id,
                           post_number: post.post_number,
                           data: {
                             message: 'expired.expired_notification',
                             display_username: current_user.username,
                             topic_title: post.topic.title
                           }.to_json
                          )
      end

      render json: success_json
    end

    def unexpire

      limit_expires

      post = Post.find(params[:id].to_i)

      guardian.ensure_can_expire_answer!(post.topic)

      post.custom_fields["is_expired_topic"] = nil
      post.topic.custom_fields["expired_topic_post_id"] = nil
      post.topic.save!
      post.save!

      # yank notification
      notification = Notification.find_by(
         notification_type: Notification.types[:custom],
         user_id: post.user_id,
         topic_id: post.topic_id,
         post_number: post.post_number
      )

      notification.destroy if notification

      render json: success_json
    end

    def limit_expires
      unless current_user.staff?
        RateLimiter.new(nil, "expire-hr-#{current_user.id}", 20, 1.hour).performed!
        RateLimiter.new(nil, "expire-min-#{current_user.id}", 4, 30.seconds).performed!
      end
    end
  end

  DiscourseExpired::Engine.routes.draw do
    post "/expire" => "answer#expire"
    post "/unexpire" => "answer#unexpire"
  end

  Discourse::Application.routes.append do
    mount ::DiscourseExpired::Engine, at: "solution"
  end

  TopicView.add_post_custom_fields_whitelister do |user|
    ["is_expired_topic"]
  end

  if Report.respond_to?(:add_report)
    AdminDashboardData::GLOBAL_REPORTS << "expired_topic"

    Report.add_report("expired_topic") do |report|
      report.data = []
      expired_topic = TopicCustomField.where(name: "expired_topic_post_id")
      expired_topic = expired_topic.joins(:topic).where("topics.category_id = ?", report.category_id) if report.category_id
      expired_topic.where("topic_custom_fields.created_at >= ?", report.start_date)
                        .where("topic_custom_fields.created_at <= ?", report.end_date)
                        .group("DATE(topic_custom_fields.created_at)")
                        .order("DATE(topic_custom_fields.created_at)")
                        .count
                        .each do |date, count|
        report.data << { x: date, y: count }
      end
      report.total = expired_topic.count
      report.prev30Days = expired_topic.where("topic_custom_fields.created_at >= ?", report.start_date - 30.days)
                                            .where("topic_custom_fields.created_at <= ?", report.start_date)
                                            .count
    end
  end

  require_dependency 'topic_view_serializer'
  class ::TopicViewSerializer
    attributes :expired_topic

    def include_expired_topic?
      expired_topic_post_id
    end

    def expired_topic
      if info = expired_topic_post_info
        {
          post_number: info[0],
          username: info[1],
        }
      end
    end

    def expired_topic_post_info
      # TODO: we may already have it in the stream ... so bypass query here

      Post.where(id: expired_topic_post_id, topic_id: object.topic.id)
          .joins(:user)
          .pluck('post_number, username')
          .first
    end

    def expired_topic_post_id
      id = object.topic.custom_fields["expired_topic_post_id"]
      # a bit messy but race conditions can give us an array here, avoid
      id && id.to_i rescue nil
    end

  end

  class ::Category
    after_save :reset_expired_cache

    protected
    def reset_expired_cache
      ::Guardian.reset_expired_topic_cache
    end
  end

  class ::Guardian

    @@allowed_expired_cache = DistributedCache.new("allowed_expired")

    def self.reset_expired_topic_cache
      @@allowed_expired_cache["allowed"] =
        begin
          Set.new(
            CategoryCustomField
              .where(name: "enable_expired_topics", value: "true")
              .pluck(:category_id)
          )
        end
    end

    def allow_expired_topics_on_category?(category_id)
      return true if SiteSetting.allow_expired_on_all_topics

      self.class.reset_expired_topic_cache unless @@allowed_expired_cache["allowed"]
      @@allowed_expired_cache["allowed"].include?(category_id)
    end

    def can_expire_answer?(topic)
      allow_expired_topics_on_category?(topic.category_id) && (
        is_staff? || (
          authenticated? && !topic.closed? && topic.user_id == current_user.id
        )
      )
    end
  end

  require_dependency 'post_serializer'
  class ::PostSerializer
    attributes :can_expire_answer, :can_unexpire_answer, :expired_topic

    def can_expire_answer
      topic = (topic_view && topic_view.topic) || object.topic

      if topic
        scope.can_expire_answer?(topic) &&
        object.post_number >=0 && !expired_topic
      end
    end

    def can_unexpire_answer
      topic = (topic_view && topic_view.topic) || object.topic
      if topic
        scope.can_expire_answer?(topic) && post_custom_fields["is_expired_topic"]
      end
    end

    def expired_topic
      post_custom_fields["is_expired_topic"]
    end
  end

  require_dependency 'search'

  #TODO Remove when plugin is 1.0
  if Search.respond_to? :advanced_filter
    Search.advanced_filter(/in:expired/) do |posts|
      posts.where("topics.id IN (
        SELECT tc.topic_id
        FROM topic_custom_fields tc
        WHERE tc.name = 'expired_topic_post_id' AND
                        tc.value IS NOT NULL
        )")

    end

    Search.advanced_filter(/in:unexpired/) do |posts|
      posts.where("topics.id NOT IN (
        SELECT tc.topic_id
        FROM topic_custom_fields tc
        WHERE tc.name = 'expired_topic_post_id' AND
                        tc.value IS NOT NULL
        )")

    end
  end

  require_dependency 'topic_list_item_serializer'

  class ::TopicListItemSerializer
    attributes :has_expired_topic

    def include_has_expired_topic?
      object.custom_fields["expired_topic_post_id"]
    end

    def has_expired_topic
      true
    end
  end

  TopicList.preloaded_custom_fields << "expired_topic_post_id" if TopicList.respond_to? :preloaded_custom_fields

end
