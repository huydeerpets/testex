import PostView from 'discourse/views/post';
import PostMenuComponent from 'discourse/components/post-menu';
import { Button } from 'discourse/components/post-menu';
import Topic from 'discourse/models/topic';
import User from 'discourse/models/user';
import TopicStatus from 'discourse/views/topic-status';
import computed from 'ember-addons/ember-computed-decorators';
import { popupAjaxError } from 'discourse/lib/ajax-error';

export default {
  name: 'extend-for-expired-button',
  initialize: function() {

    Topic.reopen({
      // keeping this here cause there is complex localization
      expiredAnswerHtml: function(){
        const username = this.get('expired_topic.username');
        var postNumber = this.get('expired_topic.post_number');

        if (!username || !postNumber) {
          return "";
        }

        return I18n.t("expired.expired_html", {
          username_lower: username.toLowerCase(),
          username,
          post_path: this.get('url') + "/" + postNumber,
          post_number: postNumber,
          user_path: User.create({username: username}).get('path')
        });
      }.property('expired_topic', 'id')
    });

    TopicStatus.reopen({
      statuses: function(){
        var results = this._super();
        if (this.topic.has_expired_topic) {
          results.push({
            openTag: 'span',
            closeTag: 'span',
            title: I18n.t('expired.has_expired_topic'),
            icon: 'expired',
			key: 'locked_and_archived'
          });
        }
        return results;
      }.property()
    });

    PostView.reopen({
      classNameBindings: ['post.expired_topic:expired-answer']
    });

    PostMenuComponent.registerButton(function(visibleButtons){
      var position = 0;

      var canExpire = this.get('post.can_expire_answer');
      var canUnexpire = this.get('post.can_unexpire_answer');
      var expired = this.get('post.expired_topic');
      var isOp = User.currentProp("id") === this.get('post.topic.user_id');

      if  (!expired && canExpire && !isOp) {
        // first hidden position
        if (this.get('collapsed')) { return; }
        position = visibleButtons.length - 2;
      }
      if (canExpire) {
        visibleButtons.splice(position,0,new Button(
		'expireAnswer', 
		'expired.expire_answer', 
		'square-o', 
		{className: 'unexpired', prefixHTML: '<span class="expired-text">' + I18n.t('expired.solution') + '</span>'}));
      }
      if (canUnexpire || expired) {
        var locale = canUnexpire ? 'expired.unexpire_answer' : 'expired.expired_topic';
        visibleButtons.splice(position,0,new Button(
            'unexpireAnswer',
            locale,
            'check-square',
            {className: 'expired fade-out', prefixHTML: '<span class="expired-text">' + I18n.t('expired.solution') + '</span>'})
          );
      }

    });

    PostMenuComponent.reopen({
      expiredChanged: function(){
        this.rerender();
      }.observes('post.expired_topic'),

      clickUnexpireAnswer: function(){
        if (!this.get('post.can_unexpire_answer')) { return; }

        this.set('post.can_expire_answer', true);
        this.set('post.can_unexpire_answer', false);
        this.set('post.expired_topic', false);
        this.set('post.topic.expired_topic', undefined);

        Discourse.ajax("/solution/unexpire", {
          type: 'POST',
          data: {
            id: this.get('post.id')
          }
        }).catch(popupAjaxError);
      },

      clearExpiredAnswer: function(){
        const posts = this.get('post.topic.postStream.posts');
        posts.forEach(function(post){
          if (post.get('post_number') > 1 ) {
            post.set('expired_topic',false);
            post.set('can_expire_answer',true);
            post.set('can_unexpire_answer',false);
          }
        });
      },

      clickExpireAnswer: function(){

        this.clearExpiredAnswer();

        this.set('post.can_unexpire_answer', true);
        this.set('post.can_expire_answer', false);
        this.set('post.expired_topic', true);

        this.set('post.topic.expired_topic', {
          username: this.get('post.username'),
          post_number: this.get('post.post_number')
        });

        Discourse.ajax("/solution/expire", {
          type: 'POST',
          data: {
            id: this.get('post.id')
          }
        }).catch(popupAjaxError);
      }
    });
  }
};
