class CalendarEventsController < ApplicationController
  
  def show
    @calendar_event = CalendarEvent.find(params[:id])
    @action_data = @calendar_event.get_action_data(true)
    @time_zone = current_user.get_time_zone
    render json: {content: load_show}, status: 200
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  def holiday_show
    name = params[:name]
    date = Date.strptime(params[:date], "%m/%d/%Y")
    throw(:CEH01, "Event not found")  if name.blank? || date.blank?
    
    @time_zone = current_user.get_time_zone
    dt = date.to_time.asctime.in_time_zone(@time_zone)  # Set time zone without changing hour, will be starting dt
    @calendar_event = CalendarEvent.new(parent_organization_id: current_user.parent_organization_id, type_of: "holiday", name: name, all_day: true,
                                        is_public: true, start_at: dt.utc, end_at: dt.end_of_day.end_of_day.utc)
    render json: {content: load_show}, status: 200
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  def new
    @time_zone = current_user.get_time_zone  # Checks org, parent_org, else default to PST
    parent_org = current_user.parent_organization
    date = Time.strptime(params[:start_date], "%Y-%m-%d")
    
    if params[:copy_id].present?  # Opened via copy tooltip
      calendar_event = parent_org.get_calendar_events.find(params[:copy_id])
      @calendar_event = CalendarEvent.new(calendar_event.as_json.reject{|k, _v| %w(id created_at updated_at).include?(k)})
      cer_data = @calendar_event.cer_data(show_order: true)  # calendar_event_recipients sorted by access
      @involved_users = (cer_data[:involved].present? ? cer_data[:involved] : [])
      @view_only_users = (cer_data[:view_only].present? ? cer_data[:view_only] : [])
      month, day, year = date.month, date.day, date.year
      @start_at = @calendar_event.start_at.change({month: month, day: day, year: year}).in_time_zone(@time_zone)
      @end_at = @calendar_event.end_at.change({month: month, day: day, year: year}).in_time_zone(@time_zone)
      @recipient = @calendar_event.recipient
    else  # Standard open
      time_base = round_dt_to_minutes(TextFormat.time_in_tz(Time.now, @time_zone), 15)
      start = date.change({ hour: time_base.hour, min: time_base.min })
      @start_at, @end_at = (start + 1.hour), (start + 2.hours)
      
      @calendar_event = CalendarEvent.new(parent_organization_id: parent_org.id, organization_id: current_user.organization_id, created_by: current_user.id)
      @involved_users = [OpenStruct.new(entity_type: "USER", entity_id: current_user.id, entity_name: current_user.full_name)]  # Set current_user as first recipient, mimic info from get_calendar_event_recipients
      @view_only_users = []
    end
    
    @action_data, @cea_options = @calendar_event.get_action_data(false, true)  # Get default for building form HTML
    @type_select = load_type_select
    @form_action = "add"
    @actions_tooltip = render_to_string(partial: "calendar_events/actions_tooltip", formats: "html")  # Saved to JS variable on form for quick loading
    @user_dept_add_tlt = render_to_string(partial: "calendar_events/user_dept_tooltip", formats: "html")  # Saved to JS variable on form for quick loading
    @campus_select = CalendarEvent.campus_select_w_tz(parent_org)
    load_time_selects  # Loads @hour_select, @min_select, and @mer_select
    render json: {content: render_to_string(partial: "calendar_events/form", formats: "html")}
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  def create
    user = current_user
    @time_zone = get_time_zone_from_param_data(user)  # Check through org and parent org ids in params, default to check user
    set_datetime_params  # Dates/times collected individually on form
    
    ApplicationRecord.transaction do
      @calendar_event = CalendarEvent.create!(calendar_event_params)
      @calendar_event.crud_calendar_event_recipients(params[:calendar_event_recipients], user)
      
      if @calendar_event.is_appointment?
        create_calendar_event_tagging("add", user)
        (cea = CalendarEventAction.create!(calendar_event_id: @calendar_event.id, data: params[:calendar_event_action_data]))  if params[:calendar_event_action_data].present?
        (cea.execute_actions("event_creation", @calendar_event.recipient, @calendar_event.appointment_user))  if cea.present?  # Execute actions for type if any
      end
      (@calendar_event.send_event_email_notices(user))  if params[:email_notices].present?
      (@calendar_event.send_event_text_notices(:c, params[:text_notices], user))  if params[:text_notices].present? && %w[recipient all].include?(params[:text_notices])
    end
    
    @start_date = @calendar_event.start_at  # Reload show and month
    show_data, month_data = load_show, load_month  # @recipient loaded within show_data, reloads calendar_events/show
    appt_content, show_page_data = load_rcpt_show_data  # Returns data when params[:source][:page] is student or lead show page, else nil
    my_assist_ce_data = load_my_assistant_data  # Returns data when params[:source][:page] = "my_assistant_index"
    
    render json: {message: "Event created.", content: show_data, month_data: month_data, start_date: @calendar_event.start_at.to_date.to_s, appt_content: appt_content,
                  show_data: show_page_data, my_assist_ce_data: my_assist_ce_data}, status: 200
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  def edit
    parent_org = current_user.parent_organization
    @calendar_event = parent_org.get_calendar_events.find(params[:id])
    cer_data = @calendar_event.cer_data(show_order: true)  # calendar_event_recipients sorted by access
    @involved_users = (cer_data[:involved].present? ? cer_data[:involved] : [])
    @view_only_users = (cer_data[:view_only].present? ? cer_data[:view_only] : [])
    
    @time_zone = current_user.get_time_zone  # Checks org, parent_org, else default to PST
    @start_at, @end_at = TextFormat.time_in_tz(@calendar_event.start_at, @time_zone), TextFormat.time_in_tz(@calendar_event.end_at, @time_zone)
    @recipient = @calendar_event.recipient
    @appt_user = @calendar_event.appointment_user
    
    @action_data, @cea_options = @calendar_event.get_action_data(false, true)  # Get action data sorted by type or default for building form HTML and options data
    @actions_present = @action_data.values.collect{|v| v.present?}.include?(true)  # Check if data is present in case default is returned
    @type_select = load_type_select
    @form_action = "edit"
    @actions_tooltip = render_to_string(partial: "calendar_events/actions_tooltip", formats: "html")  # Saved to JS variable on form for quick loading
    @user_dept_add_tlt = render_to_string(partial: "calendar_events/user_dept_tooltip", formats: "html")  # Saved to JS variable on form for quick loading
    @campus_select = CalendarEvent.campus_select_w_tz(parent_org)
    load_time_selects  # Loads @hour_select, @min_select, and @mer_select
    render json: {content: render_to_string(partial: "calendar_events/form", formats: "html")}
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  def update
    @calendar_event = CalendarEvent.find(params[:id])
    user = current_user
    @time_zone = get_time_zone_from_param_data(user)  # Check through org and parent org ids in params, default to check user
    set_datetime_params  # Dates/times collected individually on form
    
    ApplicationRecord.transaction do
      @calendar_event.update_attributes!(calendar_event_params)
      @calendar_event.crud_calendar_event_recipients(params[:calendar_event_recipients], user)
      @calendar_event.crud_calendar_event_action(params[:calendar_event_action_data], user)
      (update_add_tagging_note)  if @calendar_event.is_appointment?
      (@calendar_event.send_event_email_notices(user, {action: :u2}))  if params[:email_notices].present?
      (@calendar_event.send_event_text_notices(:u, params[:text_notices], user))  if params[:text_notices].present? && %w[recipient all].include?(params[:text_notices])
    end
    
    @start_date = @calendar_event.start_at  # Reload show and month
    ce_show_data, month_data = load_show, load_month  # @recipient loaded within show_data
    appt_content, show_data = load_rcpt_show_data  # Returns data when params[:source][:page] is student or lead show page, else nil
    my_assist_ce_data = load_my_assistant_data  # Returns data when params[:source][:page] = "my_assistant_index"
    
    render json: {message: "Event updated.", content: ce_show_data, month_data: month_data, start_date: @calendar_event.start_at.to_date.to_s,
                  appt_content: appt_content, show_data: show_data, my_assist_ce_data: my_assist_ce_data}, status: 200
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  def destroy
    user = current_user
    @calendar_event = CalendarEvent.find(params[:id])
    @calendar_event.update_attributes!(deleted_at: Time.now.utc, deleted_by: user.id)
    (create_calendar_event_tagging("delete", user))  if @calendar_event.is_appointment?
    @calendar_event.delete_related_data
    @calendar_event.send_event_email_notices(user, {action: :d})
    
    @start_date = @calendar_event.start_at  # Reload day and month
    @time_zone = user.get_time_zone
    @recipient = @calendar_event.recipient
    day_data, month_data = load_day, load_month
    appt_content, show_data = load_rcpt_show_data  # Returns data when params[:source][:page] is student or lead show page, else nil
    my_assist_ce_data = load_my_assistant_data  # Returns data when params[:source][:page] = "my_assistant_index"
    
    render json: {message: "Event removed.", content: day_data, month_data: month_data, appt_content: appt_content,
                  show_data: show_data, my_assist_ce_data: my_assist_ce_data}, status: 200
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  def update_appointment_status
    @calendar_event = CalendarEvent.find(params[:id])
    status = params[:appointment_status]
    
    @calendar_event.update_attributes!(appointment_status: status, appt_status_updated_at: Time.now.utc)
    if @calendar_event.is_appointment?
      create_calendar_event_tagging("appt_status", current_user)
      cea = @calendar_event.calendar_event_action
      (cea.execute_actions("appt_#{status}", @calendar_event.recipient, @calendar_event.appointment_user))  if cea.present?  # Execute actions for type if any
    end
    
    if params[:reload].present?  # Called from outside of calendar, page will be reloaded
      flash[:success] = "Appointment status updated."
      render json: {content: "ok"}, status: 200
    else  # Called from within calendar
      @time_zone = current_user.get_time_zone  # Reload show
      show_data = load_show  # Reload calendar_events/show
      show_page_data = load_rcpt_show_data  # Returns data when params[:source][:page] is student or lead show page, else nil
      render json: {message: "Appointment status updated.", content: show_data, show_data: show_page_data}, status: 200
    end
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  def download_ics_file
    @calendar_event = current_user.parent_organization.get_calendar_events.find(params[:id])
    ical = @calendar_event.generate_ics_file
    send_data(ical.to_ical, filename: "#{TextFormat.filename_format(@calendar_event.name)}.ics", type: "text/calendar", disposition: "attachment")
  rescue Exception => e
    err = handle_error(e)
    flash[:notice] = err.message
    redirect_back(fallback_location: "/")
  end
  
  def info
    case params[:type]
      when "copy_tooltip"
        @calendar_event = current_user.parent_organization.get_calendar_events.find(params[:id])
        render json: {content: render_to_string(partial: "calendar_events/copy_tooltip", formats: "html")}, status: 200
      when "check_dt_availability"
        parent_org = ParentOrganization.find(params[:parent_organization_id])
        org = (params[:organization_id].present? ? Organization.find(params[:organization_id]) : nil)
        @time_zone = (org.present? ? org.get_time_zone : parent_org.get_time_zone)
        set_datetime_params
        @start_at, @end_at = params[:calendar_event][:start_at], params[:calendar_event][:end_at]
        curr_ce_id = params[:calendar_event_id]  # Will be excluded from checks if id present from edit
        @notices = {}
        
        # Check for federal holidays
        fed_hols = ((@start_at.to_date != @end_at.to_date) ? Holidays.between(@start_at.to_date, @end_at.to_date, :us) : Holidays.on(@start_at.to_date, :us))
        # Check as range or single date, data is same for both
        if fed_hols.present?  # fed_hols: [{date: Date, name: "Holiday Name", regions: Array}, ...]
          @notices["Federal Holiday#{"s" if fed_hols.length > 1}"] = fed_hols.each_with_object([]) {|h, arr| arr << "#{h[:date].strftime("%m/%d/%Y")} - #{h[:name]}"}
        end
        
        # Check overlap with other calendar events for involved users
        user_ids, dept_ids = [], []
        params[:calendar_event_recipients].each do |_i, data|
          (data[:type] == "DEPARTMENT") ? (dept_ids << data[:id]) : (user_ids << data[:id])
        end
        if dept_ids.present?  # Look up users in department in 1 query in case of multiple departments
          du_ids = parent_org.get_users(departments: dept_ids, multicampus: true).pluck(:id)
          (user_ids += du_ids)  if dept_ids.present?  # Append user ids from department
        end
        users = User.where(id: user_ids.uniq).group("id")
        
        users_w_overlap = []
        users.each do |user|
          user_ces = user.get_calendar_events(exclude_id: curr_ce_id, date_range: {start: @start_at, end: @end_at}, view_only: 0).order("calendar_events.start_at ASC")  # Exclude view only events
          if user_ces.present?
            users_w_overlap << "#{user.full_name} - #{user_ces.map{|ce| ce.date_time_display(@time_zone, "short")}.join(", ")}"
          end
        end
        (@notices["User Calendar Events"] = users_w_overlap)  if users_w_overlap.present?
        
        # Check recipient calendar_event overlap if present
        rcpt = (params[:recipient].present? ? EntityType.get_entity(params[:recipient][:type], params[:recipient][:id]) : nil)
        if rcpt.present?
          rcpt_ces = rcpt.get_calendar_events(exclude_id: curr_ce_id, date_range: {start: @start_at, end: @end_at}, view_only: 0).order("calendar_events.start_at ASC")  # Exclude view only events
          if rcpt_ces.present?
            @notices["Recipient Appointment#{"s" if rcpt_ces.length > 1}"] = ["#{rcpt.full_name} - #{rcpt_ces.map{|ce| ce.date_time_display(@time_zone, "short")}.join(", ")}"]
          end
        end
        
        render json: {content: (@notices.present? ? render_to_string(partial: "calendar_events/form_notice_confirm", formats: "html") : nil)}, status: 200
      when "holiday_list"  # Display list of holidays between 2 dates in popup or tooltip
        @start_date, @end_date = Date.strptime(params[:start_date], "%m/%d/%Y"), Date.strptime(params[:end_date], "%m/%d/%Y")
        @holidays = Holidays.between(@start_date, @end_date, :us)
        @view = (params[:view] || "popup")  # Default to popup
        render json: {content: render_to_string(partial: "calendar_events/holiday_list", formats: "html")}, status: 200
    else
      throw(:CC02, "TYPE MISSING OR INVALID")
    end
  rescue Exception => e
    err = handle_error(e)
    render json: {message: err.message}, status: err.status
  end
  
  private
  
  def set_datetime_params
    # Convert to 24 format if needed
    if params[:calendar_event][:all_day] == "true"  # Set times to start and end of day for all day option
      params[:calendar_event][:start_at] = Time.strptime("#{params[:start_at][:date]} 00:00", "%m/%d/%Y %H:%M").asctime.in_time_zone(@time_zone).utc  # Set time zone without changing time
      params[:calendar_event][:end_at] = Time.strptime("#{params[:end_at][:date]} 23:55", "%m/%d/%Y %H:%M").asctime.in_time_zone(@time_zone).utc
    else  # Else parse both date and time
      start_at = ((params[:start_at][:time].length > 5) ? Time.parse(params[:start_at][:time]).strftime("%H:%M") : params[:start_at][:time])
      end_at = ((params[:end_at][:time].length > 5) ? Time.parse(params[:end_at][:time]).strftime("%H:%M") : params[:end_at][:time])
      
      params[:calendar_event][:start_at] = Time.strptime("#{params[:start_at][:date]} #{start_at}", "%m/%d/%Y %H:%M").asctime.in_time_zone(@time_zone).utc  # Set time zone without changing time
      params[:calendar_event][:end_at] = Time.strptime("#{params[:end_at][:date]} #{end_at}", "%m/%d/%Y %H:%M").asctime.in_time_zone(@time_zone).utc
    end
  end
  
  def calendar_event_params
    params.require(:calendar_event).permit(
      :parent_organization_id, :organization_id, :type_of, :start_at, :end_at, :name, :location, :description, :recipient_type, :recipient_id, :is_public, :appointment_status,
      :appt_status_updated_at, :created_by, :recipient_type, :deleted_by, :deleted_at, :appt_user_id, :all_day).transform_values{|v| (v.is_a?(String) && v.blank?) ? nil : v}  # nils blank string
  end
  
  def get_time_zone_from_param_data(user)
    if params[:calendar_event][:organization_id].present?  # User time zone of selected campus in case different from user's
      Organization.find(params[:calendar_event][:organization_id]).get_time_zone
    elsif params[:calendar_event][:parent_organization_id].present?
      ParentOrganization.find(params[:calendar_event][:parent_organization_id]).get_time_zone
    else
      user.get_time_zone
    end
  end
  
  def load_time_selects
    @hour_select = (1..12).map{|x| x.to_s.rjust(2, "0")}
    @min_select = (0..11).map{|x| (x * 5).to_s.rjust(2, "0")}  # Minutes in increments of 5
    @mer_select = %w[AM PM]
  end
  
  def load_show
    if @calendar_event.id.present?  # @calendar_event via holiday_show will not have an id
      @recipient ||= @calendar_event.recipient
      @appt_user = @calendar_event.appointment_user
      @show_appt_status = (@calendar_event.appointment_status.present? || @calendar_event.needs_completion?(@time_zone))
      
      cer_data = @calendar_event.cer_data(show_order: true)  # calendar_event_recipients sorted by access
      @involved_users = (cer_data[:involved].present? ? cer_data[:involved] : [])
      @view_only_users = (cer_data[:view_only].present? ? cer_data[:view_only] : [])
      
      @user_write_access = @calendar_event.user_has_write_access?(current_user, @involved_users)
      @action_data = @calendar_event.get_action_data(true)
    end
    render_to_string(partial: "calendar_events/show", formats: "html")
  end
  
  def load_month
    Time.zone = @time_zone  # Must set for correct month day display with simple_calendar
    Date.beginning_of_week = :sunday  # Must set for correct week start in month display with simple_calendar
    params[:start_date] = @start_date  # Add to params for correct month display with simple_calendar
    date_range = CalendarEvent.get_start_range(@start_date, "month", @time_zone)
    filters = parse_filters(params[:filters])
    @calendar_events = current_user.get_calendar_events({date_range: date_range, appt_user: true, recipient: true, include_public: true}.merge(filters))
    render_to_string(partial: "calendars/main_monthly", formats: "html")
  end
  
  def load_day
    date_range = CalendarEvent.get_start_range(@start_date.to_date, "day", @time_zone)
    filters = parse_filters(params[:filters])
    @calendar_events = current_user.get_calendar_events({date_range: date_range, appt_user: true, recipient: true, include_public: true}.merge(filters)).order("calendar_events.start_at ASC")
    render_to_string(partial: "calendars/main_daily", formats: "html")
  end
  
  def load_rcpt_show_data  # Load if source is student/lead show page and recipient of calendar event is same as page source
    if @calendar_event.is_appointment? && params[:source].present? && %w[students_show student_leads_show].include?(params[:source][:page])
      source_entity = EntityType.find_entity(params[:source][:type], decode_base64(params[:source][:id]))
      @recipient ||= @calendar_event.recipient
      organization = @recipient.organization
      
      if (@recipient.class.to_s == source_entity.class.to_s) && (@recipient.id == source_entity.id)
        @source = params[:source][:page].gsub("_show", "#show")  # @source used in refresh_data_for_show function in "students#show" format
        case action_name  # Controller action name
          when "update_appointment_status" then refresh_data_for_show(@recipient, "ADD", {organization: organization})
          else [load_rcpt_appointments, refresh_data_for_show(@recipient, "ADD", {organization: organization})]
        end
      end
    end
  end
  
  def load_rcpt_appointments  # Load student/lead show page appointments section and log/taggings
    @parent_admin = current_user.is_at_least_parent_org_admin?
    ce_data = {end_at: Time.now.utc.in_time_zone(@time_zone), appt_user: true, user_is_rcpt: (@parent_admin ? nil : current_user.id)}
    calendar_events = @recipient.get_calendar_events(ce_data).order("calendar_events.start_at ASC")  # User recipient check not needed for parent admins
    @calendar_events = (calendar_events.present? ? CalendarEvent.sort_by_start_date(calendar_events) : nil)
    render_to_string(partial: "calendar_events/recipient_events", formats: "html")
  end
  
  def load_my_assistant_data
    if @calendar_event.is_appointment? && params[:source].present? && (params[:source][:page] == "my_assistant_index")
      load_user_my_assistant_ce(organization_id: params[:source][:organization_id])
    end
  end
  
  def load_user_my_assistant_ce(**data)
    @time_zone ||= current_user.get_time_zone
    q_data = {start_at: Time.now.in_time_zone(@time_zone).beginning_of_day, appt_user: true, recipient: true, view_only: 0}  # Exclude view only events
    (q_data[:organization_id] = data[:organization_id])  if data[:organization_id].present?
    
    calendar_events = current_user.get_calendar_events(q_data).order("calendar_events.start_at ASC").limit(10)
    @calendar_events = (calendar_events.present? ? CalendarEvent.sort_by_start_date(calendar_events) : nil)
    @cal_links = true  # Dates and event names provide calendar links in users/calendar_event_summary partial
    @show_rcpt_phone = true  # Display recipient phone number, if any, on users/calendar_event_summary partial
    %(<div class="cal_display">#{render_to_string(partial: "users/calendar_event_summary", formats: "html")}</div>)
  end
  
  def parse_filters(data)
    filters = {}
    (data.each{ |k, v| (filters[k.to_sym] = v) if v.present? })  if data.present?
    filters
  end
  
  def create_calendar_event_tagging(type, user)  # Tagging only needed for appointments
    recipient = (@recipient || @calendar_event.recipient)
  
    if recipient.present?
      tag_id = case type  # Only student and student_leads for now
        when "add" then ((@calendar_event.recipient_type == 'STUDENT') ? 1161 : 1164)  # "Appointment Added" tagging
        when "delete" then ((@calendar_event.recipient_type == 'STUDENT') ? 1162 : 1165)  # "Appointment Deleted" tagging
        when "appt_status" then ((@calendar_event.recipient_type == 'STUDENT') ? 1163 : 1166)  # "Appointment Status Updated" tagging
      end
      
      note = calendar_event_tagging_note(type)
      recipient.create_tagging_alt(tag_id, {user_id: user.id, created_by: user.id, data: @calendar_event.data_id}, note)
    end
  end
  
  def calendar_event_tagging_note(type)
    note = ((type == "appt_status") ?  "#{@calendar_event.appointment_status.titleize} - #{@calendar_event.name}" : @calendar_event.name)
    @appt_user ||= @calendar_event.appointment_user
    note += " with #{@appt_user.full_name} (#{@calendar_event.date_time_display(@time_zone, "short")})"
    note
  end
  
  def update_add_tagging_note
    add_tagging = @calendar_event.get_add_tagging
    note = (add_tagging.present? ? add_tagging.log_note : nil)
    (note.update_attributes!(content: calendar_event_tagging_note("add")))  if note.present?
  end
  
  def load_type_select
    if CalendarEvent::EXTERNAL_TYPES.include?(@calendar_event.type_of)
      [["", nil]] + CalendarEvent.event_type_select("CERT")
    else
      [["", nil]] + CalendarEvent.event_type_select
    end
  end
  
end
