class ApiV1::APIController < ApplicationController
  include Oauth::Controllers::ApplicationControllerMethods
  Oauth2Token = ::Oauth2Token
  
  skip_before_filter :rss_token, :recent_projects, :touch_user, :verify_authenticity_token, :add_chrome_frame_header

  API_LIMIT = 50

  protected
  
  rescue_from CanCan::AccessDenied do |exception|
    api_error(:unauthorized, :type => 'InsufficientPermissions', :message => 'Insufficient permissions')
  end
  
  def current_user
    @current_user ||= (login_from_session ||
                       login_from_basic_auth ||
                       login_from_cookie ||
                       login_from_oauth) unless @current_user == false
  end
  
  def login_from_oauth
    user = Authenticator.new(self,[:token]).allow? ? current_token.user : nil
    user.current_token = current_token if user
    user
  end
  
  def access_denied
    api_error(:unauthorized, :type => 'AuthorizationFailed', :message => @access_denied_message || 'Login required')
  end
  
  def invalid_oauth_response(code=401,message="Invalid OAuth Request")
    @access_denied_message = message
    false
  end
  
  def load_project
    project_id ||= params[:project_id]
    
    if project_id
      @current_project = Project.find_by_id_or_permalink(project_id)
      api_error :not_found, :type => 'ObjectNotFound', :message => 'Project not found' unless @current_project
    end
  end
  
  def load_organization
    organization_id ||= params[:organization_id]
    
    if organization_id
      @organization = Organization.find_by_id_or_permalink(organization_id)
      api_error :not_found, :type => 'ObjectNotFound', :message => 'Organization not found' unless @organization
    end
  end
  
  def belongs_to_project?
    if @current_project
      unless Person.exists?(:project_id => @current_project.id, :user_id => current_user.id)
        api_error(:unauthorized, :type => 'InsufficientPermissions', :message => t('common.not_allowed'))
      end
    end
  end
  
  def load_task_list
    if params[:task_list_id]
      @task_list = if @current_project
        @current_project.task_lists.find(params[:task_list_id])
      else
        TaskList.find_by_id(params[:task_list_id], :conditions => {:project_id => current_user.project_ids})
      end
      api_error :not_found, :type => 'ObjectNotFound', :message => 'TaskList not found' unless @task_list
    end
  end
  
  def load_page
    if params[:page_id]
      @page = if @current_project
        @current_project.pages.find(params[:page_id])
      else
        Page.find_by_id(params[:page_id], :conditions => {:project_id => current_user.project_ids})
      end
      api_error :not_found, :type => 'ObjectNotFound', :message => 'Page not found' unless @page
    end
  end

  # Common api helpers
  
  def api_respond(object, options={})
    respond_to do |f|
      f.json { render :json => api_wrap(object, options).to_json }
      f.js   { render :json => api_wrap(object, options).to_json, :callback => params[:callback] }
    end
  end
  
  def api_status(status)
    respond_to do |f|
      f.json { render :json => {:status => status}.to_json, :status => status }
      f.js   { render :json => {:status => status}.to_json, :status => status, :callback => params[:callback] }
    end
  end
  
  def api_wrap(object, options={})
    references = if options[:references] == true
      objects_references = object.respond_to?(:collect) ? object.collect(&:references) : [object.references]
      refs = objects_references.inject({}) do |m,e|
        e.each { |k,v| m[k] = (Array(m[k]) + v).compact.uniq }
        m
      end
      load_references(refs).compact.collect { |o| o.to_api_hash(options.merge(:emit_type => true)) }
    elsif options[:references] # TODO: kill. only used in search
      Array(object).map do |obj|
        options[:references].map{|ref| obj.send(ref) }.flatten.compact
      end.flatten.uniq.map{|o| o.to_api_hash(options.merge(:emit_type => true))}
    else
      nil
    end
    
    {}.tap do |api_response|
      if object.respond_to? :each
        api_response[:type] = 'List'
        api_response[:objects] = object.map{|o| o.to_api_hash(options.merge(:emit_type => true)) }
      else
        api_response.merge!(object.to_api_hash(options.merge(:emit_type => true)))
      end
      
      api_response[:references] = references if references
    end
  end

  # refs is a hash like: table => ids to load, e.g. { :comments => [1,2,3] }
  def load_references(refs)
    # Now let's load everything else but the users
    user_ids = Array(refs.delete(:users))
    people_ids = Array(refs.delete(:people))
    
    elements = refs.collect do |ref, values|
      ref_class = ref.to_s.classify
      case ref_class
      when 'Person'
        people_ids += values
        []
      when 'Comment'
        Comment.where(:id => values).includes(:target).all
      when 'Upload'
        Upload.where(:id => values).includes(:page_slot).all
      when 'Note'
        Note.where(:id => values).includes(:page_slot).all
      when 'Conversation'
        convs = Conversation.where(:id => values).includes(:first_comment).includes(:recent_comments).includes(:watchers).all
        convs + convs.collect(&:first_comment) + convs.collect(&:recent_comments)
      when 'Task'
        tasks = Task.where(:id => values).includes(:first_comment).includes(:recent_comments).includes(:watchers).all
        tasks + tasks.collect(&:first_comment) + tasks.collect(&:recent_comments)
      else
        ref_class.constantize.where(:id => values).all
      end
    end.flatten.uniq

    # Load all people
    people = Person.where(:id => people_ids.uniq).all
    
    # Finally load the users we referenced before plus the ones associated to elements previously loaded
    user_ids = user_ids + (people + elements).collect { |e| e.respond_to? :user_id and e.user_id }.compact
    users = User.where(:id => user_ids.uniq).all

    # elements contains everything but users
    elements + users + people
  end

  def api_error(status_code, opts={})
    errors = {}
    errors[:type] = opts[:type] if opts[:type]
    errors[:message] = opts[:message] if opts[:message]
    respond_to do |f|
      f.json { render :json => {:errors => errors}.to_json, :status => status_code }
      f.js { render :json => {:errors => errors}.to_json, :status => status_code, :callback => params[:callback] }
    end
  end
  
  def handle_api_error(object,options={})
    errors = (object.try(:errors)||{}).to_hash
    errors[:type] = 'InvalidRecord'
    errors[:message] = 'One or more fields were invalid'
    respond_to do |f|
      f.json { render :json => {:errors => errors}.to_json, :status => options.delete(:status) || :unprocessable_entity }
      f.js   { render :json => {:errors => errors}.to_json, :status => options.delete(:status) || :unprocessable_entity, :callback => params[:callback] }
    end
  end
  
  def handle_api_success(object,options={})
    respond_to do |f|
      if options.delete(:is_new) || false
        f.json { render :json => api_wrap(object, options).to_json, :status => options.delete(:status) || :created }
        f.js   { render :json => api_wrap(object, options).to_json, :status => options.delete(:status) || :created }
      else
        f.json { head(options.delete(:status) || :ok) }
        f.js   { render :json => {:status => options.delete(:status) || :ok}.to_json, :callback => params[:callback] }
      end
    end
  end
  
  def api_truth(value)
    ['true', '1'].include?(value) ? true : false
  end
  
  def api_limit
    if params[:count]
      [params[:count].to_i, API_LIMIT].min
    else
      API_LIMIT
    end
  end
  
  def api_range(table_name)
    since_id = params[:since_id]
    max_id = params[:max_id]
    
    if since_id and max_id
      ["#{table_name}.id > ? AND #{table_name}.id < ?", since_id, max_id]
    elsif since_id
      ["#{table_name}.id > ?", since_id]
    elsif max_id
      ["#{table_name}.id < ?", max_id]
    else
      []
    end
  end
  
  def set_client
    request.format = :json unless request.format == :js
  end
  
end
