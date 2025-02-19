class NotesController < ApplicationController
  respond_to :html
  before_action :require_user, only: %i(create edit update delete rsvp publish_draft)
  before_action :set_node, only: %i(show)

  def index
    @pagy, @notes = pagy(published_notes.order('node.nid DESC'))
  end

  def tools
    redirect_to '/methods', status: 302
  end

  def places
    @title = 'Places'
    @pagy, @notes = pagy(Node.joins('LEFT OUTER JOIN node_revisions ON node_revisions.nid = node.nid
                         LEFT OUTER JOIN community_tags ON community_tags.nid = node.nid
                         LEFT OUTER JOIN term_data ON term_data.tid = community_tags.tid')
      .select('*, max(node_revisions.timestamp)')
      .where(status: 1, type: %w(page place))
      .includes(:revision, :tag)
      .references(:term_data)
      .where('term_data.name = ?', 'chapter')
      .group('node.nid')
      .order(Arel.sql('max(node_revisions.timestamp) DESC, node.nid')), items: 24)

    # Arel.sql is used to remove a Deprecation warning while updating to rails 5.2.

    render template: 'notes/tools_places'
  end

  def shortlink
    @node = Node.find params[:id]
    if @node.has_power_tag('question')
      redirect_to URI.parse(@node.path(:question)).path
    else
      redirect_to URI.parse(@node.path).path
    end
  end

  # display a revision, raw
  def raw
    response.headers['Content-Type'] = 'text/plain; charset=utf-8'
    render plain: Node.find(params[:id]).latest&.body
  end

  def show
    return if redirect_to_node_path?(@node)

    if @node
      if @node.has_power_tag('question') && @node.status == 1
        redirect_to @node.path(:question)
        return
      end

      alert_and_redirect_moderated
      redirect_power_tag_redirect

      impressionist(@node, 'show', unique: [:ip_address])
      @title = @node.latest.title
      @tags = @node.tags
      @tagnames = @tags.collect(&:name)
      @preview = false
      @react = params[:react]

      if params[:react]
        # query everything we need in the comments state object
        comments_record = @node
          .comments_viewable_by(current_user)
          .includes(%i(replied_comments node))
          .order('timestamp ASC')

        comments = helpers.get_react_comments(comments_record)

        current_user_json = nil

        if current_user
          current_user_json = {
            canModerate: current_user.can_moderate?,
            id: current_user[:id],
            role: current_user[:role],
            status: current_user[:status]
          }
        end

        @react_props = {
          currentUser: current_user_json,
          comments: comments,
          elementText: {
            commentFormPlaceholder: I18n.t('notes._comments.post_placeholder'),
            commentsHeaderText: helpers.translation('notes._comments.comments'),
            commentPreviewText: helpers.translation('comments._form.preview'),
            commentPublishText: helpers.translation('comments._form.publish'),
            userCommentedText: helpers.translation('notes._comment.commented')
          },
          node: {
            nodeId: @node.id,
            nodeAuthorId: @node.uid
          },
          user: current_user
        }
      end
    else
      page_not_found
    end
  end

  def print
    @node = Node.find_by(nid: params[:id], type: 'note')
    return if redirect_to_node_path?(@node)

    if @node
      impressionist(@node, 'print', unique: [:ip_address])
      render layout: "print"

    else
      page_not_found
    end
  end

  def image
    params[:size] ||= :large

    node = Node.find(params[:id])
    if node.main_image
      redirect_to URI.parse(node.main_image.path(params[:size])).path
    else
      redirect_to '/logo.png'
    end
  end

  def create
    return show_banned_flash unless current_user.status == User::Status::NORMAL

    saved, @node, @revision = new_note

    if params[:draft] == "true" && current_user.first_time_poster
      flash[:notice] = "First-time users are not eligible to create a draft."
      redirect_to '/'
      return
    elsif params[:draft] == "true"
      token = SecureRandom.urlsafe_base64(16, false)
      @node.slug = @node.slug + " token:" + token
      @node.save!
    end

    if saved
      @node.notify_callout_users
      params[:tags]&.tr(' ', ',')&.split(',')&.each do |tagname|
        @node.add_tag(tagname.strip, current_user)
      end

      if params[:event] == 'on'
        @node.add_tag('event', current_user)
        @node.add_tag('event:rsvp', current_user)
        @node.add_tag('date:' + params[:date], current_user) if params[:date]
      end

      @node.add_tag('first-time-poster', current_user) if current_user.first_time_poster

      if not_draft_and_user_is_first_time_poster? && @node.has_power_tag('question')
        flash[:first_time_post] = true
        thanks_for_question = I18n.t('notes_controller.thank_you_for_question').html_safe

        flash[:notice] = thanks_for_question

      elsif not_draft_and_user_is_first_time_poster?
        flash[:first_time_post] = true
        thanks_for_contribution = I18n.t('notes_controller.thank_you_for_contribution').html_safe
        flash[:notice] = thanks_for_contribution

      elsif params[:draft] != "true"
        question_note = I18n.t('notes_controller.question_note_published').html_safe
        research_note = I18n.t('notes_controller.research_note_published').html_safe

        flash[:notice] = @node.has_power_tag('question') ? question_note : research_note

      else
        flash[:notice] = I18n.t('notes_controller.saved_as_draft').html_safe
      end

      if params[:redirect] && params[:redirect] == 'question'
        redirect_to @node.path(:question)
      else
        request.xhr? ? (render plain: @node.path) : (redirect_to @node.path)
      end
    else
      if request.xhr? # rich editor!
        errors = @node.errors
        errors = errors.to_hash.merge(@revision.errors.to_hash) if @revision&.errors
        render json: errors
      else
        render template: 'editor/post'
      end
    end
  end

  def preview
    return show_banned_flash unless current_user.status == User::Status::NORMAL

    @node, @img, @body = new_preview_note
    @zoom = params[:location][:zoom].to_f if params[:location].present?
    @latitude, @longitude = location
    @preview = true
    @event_date = params[:date] if params[:date]
    render template: 'notes/show'
  end

  def edit
    @node = Node.find_by(nid: params[:id], type: 'note')

    if @node
      if current_user.uid == @node.uid || current_user.admin? || @node.has_tag("with:#{current_user.username}")
        if params[:legacy]
          render template: 'editor/post'
        else
          if @node.main_image
            @main_image = @node.main_image.path(:default)
          elsif params[:main_image] && Image.find_by(id: params[:main_image])
            @main_image = Image.find_by(id: params[:main_image]).path
          elsif @image
            @main_image = @image.path(:default)
          end
          flash.now[:notice] = "This is the new rich editor. For the legacy editor, <a href='/notes/edit/#{@node.id}?#{request.env['QUERY_STRING']}&legacy=true'>click here</a>."
          render template: 'editor/rich'
        end
      else
        if @node.has_power_tag('question')
          prompt_login I18n.t('notes_controller.author_can_edit_question')
        else
          prompt_login I18n.t('notes_controller.author_can_edit_note')
        end
      end
    end
  end

  # at /notes/update/:id
  def update
    @node = Node.find(params[:id])
    if current_user.uid == @node.uid || current_user.admin? || @node.has_tag("with:#{current_user.username}")
      @revision = @node.latest
      @revision.title = params[:title]
      @revision.body = params[:body]
      @revision.timestamp = Time.now.to_i
      if params[:tags]
        params[:tags]&.tr(' ', ',')&.split(',')&.each do |tagname|
          @node.add_tag(tagname, current_user)
        end
      end
      if @revision.valid?
        @revision.save
        @node.vid = @revision.vid
        # update vid (version id) of main image
        if @node.drupal_main_image
          i = @node.drupal_main_image
          i.vid = @revision.vid
          i.save
        end
        @node.title = @revision.title
        # save main image
        if params[:main_image] && params[:main_image] != ''
          img = Image.find params[:main_image]
          unless img.nil?
            img.nid = @node.id
            @node.main_image_id = img.id
            img.save
          end
        end
        @node.save!
        flash[:notice] = I18n.t('notes_controller.edits_saved')
        format = false
        format = :question if params[:redirect] && params[:redirect] == 'question'
        if request.xhr?
          render plain: "#{@node.path(format)}?_=#{Time.now.to_i}"
        else
          redirect_to URI.parse(@node.path(format)).path + '?_=' + Time.now.to_i.to_s
        end
      else
        flash[:error] = I18n.t('notes_controller.edit_not_saved')
        if request.xhr? || params[:rich]
          errors = @node.errors
          errors = errors.to_hash.merge(@revision.errors.to_hash) if @revision&.errors
          render json: errors
        else
          render 'editor/post'
        end
      end
    end
  end

  # at /notes/delete/:id
  # only for notes
  def delete
    @node = Node.find(params[:id])
    if current_user && (current_user.uid == @node.uid || current_user.can_moderate?)
      if @node.authors.uniq.length == 1
        @node.destroy
        respond_with do |format|
          format.html do
            if request.xhr?
              render plain: I18n.t('notes_controller.content_deleted')
            else
              flash[:notice] = I18n.t('notes_controller.content_deleted')
              redirect_to '/dashboard' + '?_=' + Time.now.to_i.to_s
            end
          end
        end
      else
        flash[:error] = I18n.t('notes_controller.more_than_one_contributor')
        redirect_to '/dashboard' + '?_=' + Time.now.to_i.to_s
    end
    else
      prompt_login
    end
  end

  # notes for a given author
  def author
    @user = User.find_by(name: params[:id])
    @title = @user.name
    @pagy, @notes = pagy(Node
      .order('nid DESC')
      .where(type: 'note', status: 1, uid: @user.uid), items: 24)
    render template: 'notes/index'
  end

  # notes for given comma-delimited tags params[:topic] for author
  def author_topic
    @user = User.find_by(name: params[:author])
    @tagnames = params[:topic].split('+')
    @title = @user.name + " on '" + @tagnames.join(', ') + "'"
    @notes = @user.notes_for_tags(@tagnames)
    @unpaginated = true
    render template: 'notes/index'
  end

  # notes with high # of likes
  def liked
    @pagy, @notes = pagy(published_notes.limit(100).order(cached_likes: :desc, nid: :desc))
    render template: 'notes/index'
  end

  def recent
    @pagy, @notes = pagy(published_notes.where(created: Time.now.to_i - 1.weeks.to_i..Time.now.to_i)
                 .order('created DESC'))
    render template: 'notes/index'
  end

  # notes with high # of views
  def popular
    @pagy, @notes = pagy(published_notes
            .limit(100)
            .order(views: :desc, nid: :desc))
    render template: 'notes/index'
  end

  def rss
    limit = 20
    @notes = if params[:moderators]
               Node.limit(limit)
                 .order('nid DESC')
                 .where('type = ? AND status = 4', 'note')
             else
               Node.limit(limit)
                 .order('nid DESC')
                 .where('type = ? AND status = 1', 'note')
             end
    respond_to do |format|
      format.rss do
        render layout: false
        response.headers['Content-Type'] = 'application/xml; charset=utf-8'
        response.headers['Access-Control-Allow-Origin'] = '*'
      end
    end
  end

  def liked_rss
    @notes = Node.limit(20)
      .order('created DESC')
      .where('type = ? AND status = 1 AND cached_likes > 0', 'note')
    respond_to do |format|
      format.rss do
        render layout: false, template: 'notes/rss'
        response.headers['Content-Type'] = 'application/xml; charset=utf-8'
      end
    end
  end

  def rsvp
    @node = Node.find params[:id]
    # leave a comment
    @comment = @node.add_comment(subject: 'rsvp', uid: current_user.uid, body: 'I will be attending!')
    # make a tag
    @node.add_tag('rsvp:' + current_user.username, current_user)
    redirect_to URI.parse(@node.path).path + '#comments'
  end

  # Updates title of a wiki page, takes id and title as query string params. maps to '/node/update/title'
  def update_title
    node = Node.find params[:id].to_i
    unless current_user && current_user == node.author
      flash.keep[:error] = I18n.t('notes_controller.author_can_edit_note')
      return redirect_to URI.parse(node.path).path + "#comments"
    end
    node.update(title: params[:title])
    redirect_to URI.parse(node.path).path + "#comments"
  end

  def publish_draft
    @node = Node.find(params[:id])
    if current_user && current_user.uid == @node.uid || current_user.can_moderate? || @node.has_tag("with:#{current_user.username}")
      @node.path = @node.generate_path
      @node.slug = @node.slug.split('token').first
      @node['created'] = DateTime.now.to_i # odd assignment needed due to legacy Drupal column types
      @node['changed'] = DateTime.now.to_i
      revision = @node.latest
      revision['timestamp'] = DateTime.now.to_i # odd assignment needed due to legacy Drupal column types 
      revision.save
      @node.save
      @node.publish
      SubscriptionMailer.notify_node_creation(@node).deliver_later
      flash[:notice] = "Thanks for your contribution. Research note published! Now, it's visible publicly."
      redirect_to @node.path
    else
      flash[:warning] = "You are not author or moderator so you can't publish a draft!"
      redirect_to '/'
    end
  end

  def drafts
    @user = User.find_by(name: params[:id])
    if current_user&.can_moderate? || current_user == @user
      @pagy, @drafts = pagy(@user.drafts, items: 24)
      render template: 'notes/drafts'
    else
      flash[:warning] = "This page is only visible to the author and moderators."
      redirect_to '/'
    end
  end

  private

  def set_node
    @node = if params[:author] && params[:date] && params[:id]
              Node.find_notes(params[:author], params[:date], params[:id]) || Node.where(path: "/report/#{params[:id]}").first
            else
              Node.find(params[:id])
            end
  end

  def redirect_power_tag_redirect
    if @node.has_power_tag('redirect') && @node.status == 1
      if current_user.blank? || !current_user.can_moderate?
        redirect_to URI.parse(Node.find(@node.power_tag('redirect')).path).path
      elsif current_user.can_moderate?
        flash.now[:warning] = "Only moderators and admins see this page, as it is redirected to #{Node.find(@node.power_tag('redirect')).title}. To remove the redirect, delete the tag beginning with 'redirect:'"
      end
    end
  end

  def new_note
    Node.new_note(uid: current_user.uid,
                  title: params[:title],
                  body: params[:body],
                  main_image: params[:main_image],
                  draft: params[:draft])
  end

  def new_preview_note
    Node.new_preview_note(uid: current_user.uid,
      title: params[:title],
      body: params[:body],
      main_image: params[:main_image],
      location: params[:location])
  end

  def not_draft_and_user_is_first_time_poster?
    params[:draft] != "true" && current_user.first_time_poster
  end

  def show_banned_flash
    flash.keep[:error] = I18n.t('notes_controller.you_have_been_banned').html_safe
    redirect_to '/logout'
  end

  def location
    latitude, @longitude = @node.latitude.present? ? @node.latitude.to_f : false
    longitude = @node.longitude.present? ? @node.longitude.to_f : false

    [latitude, longitude]
  end

  def published_notes
    hidden_nids = Node.hidden_response_node_ids
    Node.research_notes
        .where('node.status = 1')
        .where.not(nid: hidden_nids)
  end
end
