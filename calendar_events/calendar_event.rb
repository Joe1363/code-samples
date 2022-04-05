class CalendarEvent < ApplicationRecord
  belongs_to :parent_organization
  belongs_to :organization, optional: true
  has_many :calendar_event_recipients
  has_one :calendar_event_action, -> { where("deleted_at IS NULL AND deleted_by IS NULL") }
  
  require 'icalendar'
  
  # Notes:
  #  -recipient_type and recipient_id are optional, used for associating a student/lead for appointments
  #  -Ability to edit/delete events and complete appointments is limited to calendar_event_recipients with write_access = true
  #  -View only access can be set on a calendar_event_recipients with view_only = true (not considered an involved user)
  #  -deleted_by with value 0 denotes deletion by recipient
  #  -all_day option only available for non-appointment types
  #  -Federal holidays are checked via the Holidays gem and displayed on calendar via temporary new CalendarEvent objects
  
  # Some event types have specific display text, see type_of_display function for details
  EVENT_TYPES = %w[campus_appointment campus_appointment_remote campus_tour financial_aid_appointment financial_aid_appointment_remote financial_aid_packaging holiday
                   meeting orientation orientation_appointment out_of_office phone_appointment testing_appointment vacation video_chat]
  APPT_EVENT_TYPES = %w[campus_appointment campus_appointment_remote campus_tour financial_aid_appointment financial_aid_appointment_remote financial_aid_packaging
                        orientation_appointment phone_appointment testing_appointment video_chat]
  EXTERNAL_TYPES = %w[external_appointment]  # Specials cases excluded from general selection, as of now only used through calendar event request process
  APPOINTMENT_STATUSES = %w[complete rescheduled no_show]
  DAILY_VIEW_ROW_HEIGHT = 5  # In em, used within calendar daily view
  
  # Event display color based on type_of with the exception of "fedhol" (federal holiday)
  COLOR_DEFAULT = "blue"
  TYPE_OF_COLORS = {"campus_appointment" => "#6495ed", "campus_tour" => "#05a005", "external_appointment" => "grey", "fedhol" => "darkgreen",
                    "financial_aid_appointment" => "maroon", "holiday" => "olive", "meeting" => "purple", "orientation" => "darkblue", "out_of_office" => "red",
                    "phone_appointment" => "darkorange", "testing_appointment" => "coral", "vacation" => "#d4b700", "video_chat" => "#5f5f5f"}
  
  def start_date(time_zone)
    self.start_at.present? ? self.start_at.in_time_zone(time_zone).to_date : nil
  end
  
  def start_time(time_zone, format="24")  # Format options: "12", "24"
    if self.start_at.present?
      (format == "12") ? self.start_at.in_time_zone(time_zone).strftime("%H:%M") : self.start_at.in_time_zone(time_zone).strftime("%I:%M %p")
    end
  end
  
  def end_date(time_zone)
    self.end_at.present? ? self.end_at.in_time_zone(time_zone).to_date : nil
  end
  
  def end_time(time_zone, format="24")  # Format options: "12", "24"
    if self.start_at.present?
      (format == "12") ? self.end_at.in_time_zone(time_zone).strftime("%H:%M") : self.end_at.in_time_zone(time_zone).strftime("%I:%M %p")
    end
  end
  
  def self.type_of_display(type, options={})
    if type == "campus_appointment"
      "Campus Appointment - In Person"
    elsif type == "campus_appointment_remote"
      "Campus Appointment - Remote"
    elsif type == "financial_aid_appointment"
      "Financial Aid Appointment - In Person"
    elsif type == "financial_aid_appointment_remote"
      "Financial Aid Appointment - Remote"
    elsif type == "orientation_appointment"
      "Orientation - Appointment"
    elsif (type == "external_appointment") && options[:cert].present?  # For calendar_event_request_template related displays
      "External Appointment | Public Calendar Request"
    else
      type.titleize
    end
  end
  
  def type_of_display
    CalendarEvent.type_of_display(self.type_of)
  end
  
  def self.event_type_select(option=nil)
    if option == "appt"
      APPT_EVENT_TYPES.map{|et| [CalendarEvent.type_of_display(et), et]}
    elsif option == "CERT"  # calendar event request templates
      (APPT_EVENT_TYPES + EXTERNAL_TYPES).sort.map{|et| [CalendarEvent.type_of_display(et, {cert: 1}), et]}
    else
      EVENT_TYPES.map{|et| [CalendarEvent.type_of_display(et), et]}
    end
  end
  
  def creator
    self.created_by.present? ? User.find(self.created_by) : nil
  end
  
  def is_appointment?
    APPT_EVENT_TYPES.include?(self.type_of)
  end
  
  def event_color
    self.type_of.present? ? TYPE_OF_COLORS[self.type_of] : COLOR_DEFAULT
  end
  
  def appointment_user
    self.appt_user_id.present? ? User.find(self.appt_user_id) : nil
  end
  
  def get_appointment_user  # Look user up without if not found
    self.appt_user_id.present? ? User.find_by(id: self.appt_user_id) : nil
  end
  
  def self.get_start_range(start_date, range, time_zone)  # Return start and end
    date = start_date.to_time.in_time_zone(time_zone)
    case range
      when "month" then {start: date.beginning_of_month.beginning_of_week(:sunday).beginning_of_day, end: date.end_of_month.end_of_week.end_of_day}  # Includes days from last and next month showing on calendar
      when "week"  then {start: date.beginning_of_week(:sunday).beginning_of_day, end: date.end_of_week.end_of_day}
      when "day"   then {start: date.beginning_of_day, end: date.end_of_day}
      else nil
    end
  end
  
  def date_time_display(time_zone, format=nil)
    start_at, end_at = self.start_at.in_time_zone(time_zone), self.end_at.in_time_zone(time_zone)
    f_date = ((format == "short") ? "%-m/%-d/%Y" : "%A, %b %-d %Y")
    
    if self.all_day  # Only display dates for all_day
      (start_at.day == end_at.day) ? "#{start_at.strftime("#{f_date}")}" : "#{start_at.strftime("#{f_date}")} - #{end_at.strftime("#{f_date}")}"
    else
      if start_at.day == end_at.day  # Thursday, Jul 17, 1:00 PM - 2:00 PM or 7/17/2020, 1:00 PM - 2:00 PM
        "#{start_at.strftime("#{f_date}, %-I:%M%p")}-#{end_at.strftime("%-I:%M%p %Z")}"
      else  # Thursday, Jul 17, 1:00 PM - Friday, Jul 18, 2:00 PM or 7/17/2020, 1:00 PM - 7/18/2020, 2:00 PM
        "#{start_at.strftime("#{f_date}, %-I:%M %p")} - #{end_at.strftime("#{f_date}, %-I:%M %p %Z")}"
      end
    end
  end
  
  def time_display(time_zone)  # Assumes start and end days are the same
    if self.all_day
      "All Day"
    else
      start_at, end_at = self.start_at.in_time_zone(time_zone), self.end_at.in_time_zone(time_zone)
      "#{start_at.strftime("%-I:%M %p")} - #{end_at.strftime("%-I:%M %p")}"
    end
  end
  
  def date_time_display_c(time_zone)  # Only display time for single day events, else include dates
    (self.end_at.day > self.start_at.day) ? self.date_time_display(time_zone, "short") : self.time_display(time_zone)
  end
  
  def daily_display_data(date, time_zone)
    start_at, end_at = self.start_at.in_time_zone(time_zone), self.end_at.in_time_zone(time_zone)
    start_date, end_date = start_at.to_date, end_at.to_date
    row_height = DAILY_VIEW_ROW_HEIGHT
    
    # Values multiplied by height of 1 hour row (in em)
    top, height = if start_date == end_date  # Event starts and ends on same day
      [(TextFormat.time_difference(start_at.beginning_of_day, start_at) * row_height), (TextFormat.time_difference(start_at, end_at) * row_height)]
    elsif (start_date < date) && (end_date > date)  # Middle of multi-day event
      [0, (24 * row_height)]
    elsif (date == start_date) && (end_at.day > start_at.day)  # Start of multi-day event
      [(TextFormat.time_difference(start_at.beginning_of_day, start_at) * row_height), (TextFormat.time_difference(start_at, start_at.end_of_day) * row_height)]
    elsif (date == end_date) && start_at.day < end_at.day  # End of multi-day event
      [0, (TextFormat.time_difference(date.to_time.in_time_zone(time_zone).beginning_of_day, end_at) * row_height)]
    end
    {top: top, height: height}
  end
  
  def recipient
    if self.recipient_type.present? && self.recipient_id.present?
      EntityType.find_entity(self.recipient_type, self.recipient_id)
    elsif self.external_rcpt_data.present?
      data = JSON.parse(self.external_rcpt_data)
      # Add data to open struct with relevant data points so it can be used within calendar events code
      full_name = ([[data["first_name"], data["last_name"]] - [nil, ""]]).join(" ")
      OpenStruct.new(id: nil, first_name: data["first_name"], last_name: data["last_name"], full_name: full_name, internal_id: nil, get_email: data["email"],
                     get_textable_phone_number: data["phone"], get_time_zone: data["time_zone"], entity_string: "EXTERNAL")
    end
  end
  
  def self.recipient_display(recipient, name_format="last_first")  # Returns "[Student] Doe, John (ID: 4454)"
    (return nil)  if recipient.blank?
    res = "[#{recipient.entity_string.titleize}] "
    res += "#{recipient.entity_string == "EXTERNAL" ? recipient.full_name : recipient.full_name(name_format)}"
    (res += " (ID: #{recipient.internal_id})")  if recipient.internal_id.present?
    res
  end
  
  def needs_completion?(time_zone)
    if self.is_appointment?
      if self.appointment_status.present?
        false
      else  # Event completable beginning at start_at
        Time.now.in_time_zone(time_zone) >= self.start_at.in_time_zone(time_zone)
      end
    end
  end
  
  def get_calendar_event_recipients(options={})  # Does not include Student, StudentLead, or External recipient
    join_sql = ["LEFT JOIN users u ON (u.id = calendar_event_recipients.entity_id) LEFT JOIN departments dept ON (dept.id = calendar_event_recipients.entity_id)"]
    where_sql = ["calendar_event_recipients.calendar_event_id = #{self.id} AND calendar_event_recipients.deleted_at IS NULL AND calendar_event_recipients.deleted_by IS NULL"]
    select_sql = ["calendar_event_recipients.*, IF(calendar_event_recipients.entity_type = 'USER', CONCAT_WS(' ', u.first_name, LEFT(u.middle_name, 1), u.last_name), dept.name) AS entity_name"]
    order_sql = nil
    
    if options[:show_order].present?  # Order: Creator, entities w/ write_access, everyone else
      order_sql = "(CASE WHEN (calendar_event_recipients.entity_type = 'USER' AND calendar_event_recipients.entity_id = #{self.created_by}) THEN 1 " +
                        "WHEN calendar_event_recipients.write_access = TRUE THEN 2 " +
                        "ELSE 3 END)"
    end
    (where_sql << "calendar_event_recipients.view_only = #{options[:view_only]}")  if options[:view_only].present?
    
    CalendarEventRecipient.select(select_sql.join(", ")).joins(join_sql.join(" ")).where(where_sql.join(" AND ")).order(order_sql)
  end
  
  def cer_data(**options)  # Group recipient by access (involved vs view only)
    cers = (options[:calendar_event_recipients] || self.get_calendar_event_recipients(options))
    res = {involved: [], view_only: []}
    cers.each{|cer| cer.view_only ? (res[:view_only] << cer) : (res[:involved] << cer)}
    res
  end
  
  def get_calendar_event_recipient_users(options={})  # Get users from calendar_event_recipient entries of entity type USER and DEPARTMENT types
    parent_org = (options[:parent_organization] || self.parent_organization)
    user_ids, dept_ids = [], []
    
    where_sql = ["deleted_at IS NULL"]
    (where_sql << "view_only = #{options[:view_only]}")  if options[:view_only].present?
    
    self.calendar_event_recipients.where(where_sql.join(" AND ")).each do |cer|
      (user_ids << cer.entity_id)  if cer.entity_type == "USER"
      (dept_ids << cer.entity_id)  if cer.entity_type == "DEPARTMENT"
    end
    if dept_ids.present?  # Look up users in department in 1 query in case of multiple departments
      du_ids = parent_org.get_users(departments: dept_ids, organization_id: self.organization_id, multicampus: true).pluck(:id)
      (user_ids += du_ids)  if dept_ids.present?  # Append user ids from department
    end
    User.where(id: user_ids.uniq).group("id")
  end
  
  def crud_calendar_event_recipients(params, user)  # params is string in format: "type-id-write_access-view_only|..."
    current = self.get_calendar_event_recipients.map{|r| "#{r.entity_type}-#{r.entity_id}"}  # Map as string for comparison
    param_arr = []
    write_access_hash, view_only_hash = {}, {}
    init_arr =  (params.present? ? params.split("|") : [])
  
    init_arr.each do |param|
      p_split = param.split("-")  # [type, id, write_access, view_only]
      type_id = "#{p_split[0]}-#{p_split[1]}"  # type and id used for sorting
      write_access, view_only = p_split[2], p_split[3]
      param_arr << type_id
      write_access_hash[type_id] = write_access  # write_access added to hash for create after sort
      view_only_hash[type_id] = view_only  # view_only added to hash for create after sort
    end
    
    create = (param_arr - current)  # Entity in param_arr but not in current
    update = (current & param_arr)  # Entity in both current_ids and param_arr
    delete = (current - param_arr)  # Entity in current but not param_arr
    
    if create.present?
      create.each do |cr|
        self.calendar_event_recipients.create!(entity_type: cr.split("-")[0], entity_id: cr.split("-")[1], write_access: write_access_hash[cr], view_only: view_only_hash[cr])
      end
    end
  
    if update.present?
      update.each do |up|
        cer = self.get_calendar_event_recipients.where(entity_type: up.split("-")[0], entity_id: up.split("-")[1]).last
        cer.update_attributes!(write_access: write_access_hash[up], view_only: view_only_hash[up])
      end
    end
    
    if delete.present?
      delete.each do |del|
        cer = self.get_calendar_event_recipients.where(entity_type: del.split("-")[0], entity_id: del.split("-")[1]).last
        cer.update_attributes!(deleted_at: Time.now.utc, deleted_by: (user.present? ? user.id : nil))
      end
    end
  end
  
  def send_event_email_notices(user, data={})
    cer = (data[:calendar_event_recipients] || self.get_calendar_event_recipients(view_only: 0))
    recipient = self.recipient  # Student, lead, or external
    ex_rcpt = (recipient.present? && (recipient.entity_string == "EXTERNAL"))
    ac = (data[:action].present? ? data[:action] : :c)  # :c - create (default), :u - update, :u2 - update by user, :d - destroy
    
    parent_org = self.parent_organization
    cer_list = (recipient.present? ? [recipient.full_name] : [])  # Start with recipient if any
    cer_list += cer.map{|r| r.entity_name}  # Add calendar event recipients
    
    ics_file = nil
    if ac != :d  # Should be skipped for destroy/cancellation
      Timeout::timeout(45) do
        ics_file = self.generate_and_save_ics_file  # Generate ICS file and save to S3 for email attachment
      end
    end
    
    if recipient.present?  # Student, lead, or external
      rcpt_time_zone = recipient.get_time_zone
      sub_action = if ac == :u
                     " Rescheduled"
                   elsif ac == :u2
                     " Updated"
                   elsif ac == :d
                     " Canceled"
      end  # Blank for :c
      appt_user = self.appointment_user
      subject = "Appointment With #{appt_user.full_name}#{sub_action} - #{self.date_time_display(rcpt_time_zone)}"
      message = "Event Name: #{self.name}\nWhen: #{self.date_time_display(rcpt_time_zone)}#{"\nWhere: #{self.location}" if self.location.present?}\nWho: #{cer_list.join(", ")}"
      (message += "\nDescription: #{self.description}")  if self.description.present?
      if ex_rcpt  # Limited to external for now
        (message += "\n\nNeed to reschedule? #{self.reschedule_url}\nNeed to cancel? #{self.cancel_url}")  if (ac == :c) || (ac == :u)  # Skip for destroy
      end
      create_and_send_notice_email(recipient, user, subject, message, ics_file)
    end
    
    user_rcpts = self.get_calendar_event_recipient_users(view_only: 0)  # Gathers user ids from USER and DEPARTMENT recipients, exclude view only users
    if user_rcpts.present?
      subject, intro =
        case ac
          when :u then ["Calendar Event Rescheduled - #{parent_org.name}", "Calendar event has been rescheduled"]
          when :u2 then ["Calendar Event Updated - #{parent_org.name}", "Calendar event has been updated"]
          when :d then ["Calendar Event Canceled - #{parent_org.name}", "Calendar event has been canceled"]
          else ["New Calendar Event - #{parent_org.name}", "A new calendar event has been scheduled"]  # :c
        end
      org = (self.organization_id.present? ? self.organization : nil)
      campus = if org.present?
                 org.name
               else
                 ex_rcpt ? "N/A" : "All Campuses"
               end
      message = "Hi {r_fname},\n#{intro}.\n\nEvent Name: #{self.name}\nCampus: #{campus}\n" +
                "When: {dt_display}#{"\nWhere: #{self.location}" if self.location.present?}\nWho: #{cer_list.join(", ")}#{"\nDescription: #{self.description}" if self.description.present?}"
      user_rcpts.each do |rcpt|
        message_s = message.gsub("{dt_display}", self.date_time_display(user.get_time_zone))  # Add event start dt in user's time zone
        create_and_send_notice_email(rcpt, user, subject, message_s, ics_file)
      end
    end
  end
  
  def send_event_text_notices(type, option, user)  # type: :c (create), :u (update), option: "recipient" or "all"
    if self.is_appointment?
      recipient = self.recipient  # Student or lead
      org = self.organization  # Appointments should have org id
      appt_user = self.appointment_user
      
      if recipient.present?
        rcpt_start = self.start_at.in_time_zone(recipient.get_time_zone)
        msg_middle = ((type == :u) ? "updated:" : "scheduled for")  # Slight change for update
        message = ("#{self.type_of_display} with #{appt_user.full_name} from #{org.name} has been #{msg_middle} #{rcpt_start.strftime("%-I:%M %p %Z")} on #{rcpt_start.strftime("%A %B %-d, %Y")}.")
        create_and_send_notice_text(recipient, user, message, org)
      end
      
      if option == "all"
        # Beginning of message will differ by user and type (create/update)
        c_appt_user_msg = "#{self.type_of_display} has been scheduled with #{recipient.full_name} from #{org.name} for"
        c_incl_msg = %(You have been included in calendar event "#{self.name}" from #{org.name} by #{user.full_name} for)
        u_msg = %(Calendar event "#{self.name}" at #{org.name} has been updated:)
        
        user_rcpts = self.get_calendar_event_recipient_users(view_only: 0)  # Gathers user ids from USER and DEPARTMENT recipients excluding view only users
        if user_rcpts.present?
          user_rcpts.each do |rcpt|
            user_start = self.start_at.in_time_zone(rcpt.get_time_zone)  # Set date to user's time zone
            msg_start =
              if type == :u
                u_msg  # Update message same for all users
              else  # :c
                (rcpt.id == appt_user.id) ? c_appt_user_msg : c_incl_msg  # Start of message differs for appointment user
              end
            message = (msg_start + " #{user_start.strftime("%-I:%M %p %Z")} on #{user_start.strftime("%A %B %-d, %Y")}.")
            create_and_send_notice_text(rcpt, user, message, org)
          end
        end
      end
    end
  end
  
  def user_has_write_access?(user, calendar_event_recipients=nil)
    (return true)  if user.is_at_least_parent_org_admin?  # Parent admins have access to all events for now
    
    # Check user entries first
    cer = (calendar_event_recipients || self.get_calendar_event_recipients(view_only: 0))  # Exclude view only recipients
    user_string = "USER-#{user.id}-true"  # Check specifically for write_access = true
    cer_arr = cer.map{|r| "#{r.entity_type}-#{r.entity_id}-#{r.write_access}"}  # Format entries for comparison ("type-id-write_access")
    (return true)  if cer_arr.include?(user_string)  # User included and has access
    
    # Check department entries next
    dept_ids = user.get_department_assignments.pluck(:department_id)
    dept_arr = (dept_ids.present? ? dept_ids.map{|id| "DEPARTMENT-#{id}-true"} : nil)  # Format entries for comparison checking for write_access = true
    (return true)  if dept_arr.present? && (cer_arr & dept_arr).any?  # User specifically included as recipient
    
    false  # If none of the above match
  end
  
  def user_is_creator?(user)
    user.id == self.created_by
  end
  
  def get_ics_file
    Document.where(entity_type: "calendar_event", entity_id: self.id).last
  end
  
  def generate_ics_file
    ical = Icalendar::Calendar.new
    creator = self.creator
    org = (self.organization_id.present? ? self.organization : nil)
    
    time_zone = (creator.present? ? creator.get_time_zone : Conext::DEFAULT_TIME_ZONE)  # Default to PST if needed
    tzid = ActiveSupport::TimeZone.new(time_zone).tzinfo.name  # Ex. "America/Los_Angeles"
    start_at, end_at = self.start_at.in_time_zone(time_zone), self.end_at.in_time_zone(time_zone)
    
    ical.event do |e|
      e.dtstart = Icalendar::Values::DateTime.new(start_at, tzid: tzid)
      e.dtend   = Icalendar::Values::DateTime.new(end_at, tzid: tzid)
      e.summary = "#{"[#{org.short_name}] " if org.present?}#{self.name}"
      (e.description = self.description)  if self.description.present?
      (e.location = self.location)  if self.location.present?
      (e.organizer = Icalendar::Values::CalAddress.new("mailto:#{creator.email}", cn: creator.full_name))  if creator.present? && creator.email.present?
    end
    
    ical.publish
    ical
  end
  
  def generate_and_save_ics_file  # Save/update documents table/S3, returns document entry
    file = self.generate_ics_file.to_ical
    filename = "#{TextFormat.filename_format("#{self.name} #{self.start_at.strftime("%-m-%-d-%Y")}")}.ics"
    current_ics = self.get_ics_file
    
    file_io = StringIO.new(file)
    file_io.class.class_eval { attr_accessor :original_filename, :content_type }
    file_io.original_filename = filename
    file_io.content_type = "text/calendar"
    
    if current_ics.present?  # Update existing file when present in case of any updates
      current_ics.update_attributes!(type_of: "calendar_file", document: file_io)
      current_ics
    else
      Document.create!(organization_id: self.organization_id, entity_type: "calendar_event", entity_id: self.id, type_of: "calendar_file", document: file_io, document_type: "calendar_file")
    end
  end
  
  def delete_related_data
    ics_file = self.get_ics_file
    (ics_file.destroy)  if ics_file.present?
  end
  
  def event_hover_text(time_zone)  # Used in conjunction with user.get_calendar_events({appt_user: true, recipient: true}) for appointment aliases
    text = "#{self.name}#{" (#{self.type_of_display})" if self.type_of.present?}\n#{self.date_time_display(time_zone, "short")}"
    if self.is_appointment?
      text += "\nAppointment:\n#{self.appt_user_name} with #{self.recipient_name} (#{self.recipient_type_display})"
    end
    text
  end
  
  def self.sort_by_start_date(calendar_events)  # Returns hash in format {"8/8/2020" => [events], ...}
    res = {}
    if calendar_events.present?
      calendar_events.each do |ce|
        start_date = ce.start_at.strftime("%-m/%-d/%Y")
        res[start_date].present? ? (res[start_date] << ce) : (res[start_date] = [ce])
      end
    end
    res
  end
  
  def recipient_type_display
    self.recipient_type.present? ? ((self.recipient_type == "STUDENT_LEAD") ? "Lead" : self.recipient_type.titleize) : nil
  end
  
  def data_id  # data_id added to student/lead appointment taggings for look up
    "clevt#{self.id}"
  end
  
  def get_add_tagging
    if self.is_appointment?
      tag_id = ((self.recipient_type == 'STUDENT') ? 1161 : 1164)  # "Appointment Added" tagging
      Tagging.where("tag_id = #{tag_id} AND entity_type = '#{self.recipient_type}' AND entity_id = #{self.recipient_id} AND data = '#{self.data_id}'").last
    end
  end
  
  def crud_calendar_event_action(data, user=nil)
    cea = self.calendar_event_action
    
    if cea.present? && data.present?  # Update
      cea.update_attributes!(data: data)
    elsif cea.present? && data.blank?  # Delete
      cea.update_attributes!(deleted_at: Time.now.utc, deleted_by: (user.present? ? user.id : nil))
    elsif cea.blank? && data.present?  # Create
      CalendarEventAction.create!(calendar_event_id: self.id, data: data)
    end  # Else do nothing
  end
  
  def get_action_data(no_default=false, options=false)  # no_default set true for calendar_events/show, options true for calendar_events/form
    action_data = (no_default ? {} : CalendarEventTypeAction.default_data)  # Defaults set up front in case no CEA
    option_data = {}
  
    if self.is_appointment?
      cea = self.calendar_event_action
      
      if cea.present?
        ac_data = cea.get_action_data(self.organization)
        op_data = cea.get_option_data
        # Replace defaults if data present
        if ac_data.present?
          (ac_data.each{|k, v| ac_data.delete(k) if ((k == "event_creation") || v.blank?)})  if no_default  # Remove "event_creation" type and blank values, not needed for show
          action_data = ac_data
        end
        (option_data = op_data)  if op_data.present?
      end
    end
    options ? [action_data, option_data] : action_data
  end
  
  def self.campus_select_w_tz(parent_org)  # Display campus as "San Diego (PST)"
    default_tz_abbr = ActiveSupport::TimeZone.new(parent_org.get_time_zone).tzinfo.strftime("%Z")  # Display time zone with campus
    campus_select = parent_org.get_organizations.order("location ASC").map do |o|
      data = {"data-street-address": o.street_address, "data-city-state-zip": o.city_state_zip}  # Address data included for auto-loading with certain types
      ["#{o.location} (#{o.time_zone.present? ? ActiveSupport::TimeZone.new(o.time_zone).tzinfo.strftime("%Z") : default_tz_abbr})", o.id, data]
    end
    campus_select.unshift(["All Campuses (#{default_tz_abbr})", nil])
  end
  
  def self.get_users_calendar_event_data(users, start_date, end_date)  # users expected to be activerecord relationship
    users.each_with_object({}) do |u, hash|  # Map user full name to data: {"name" => {"date", [events]}, ...}
      ce = u.get_calendar_events({date_range: {start: start_date, end: end_date}, appt_user: true, recipient: true, view_only: 0}).order("calendar_events.start_at ASC")  # Exclude view only events
      ce_data = CalendarEvent.sort_by_start_date(ce)
      hash[u.full_name] = ce_data
    end
  end
  
  def duration  # Return minutes
    (self.start_at.present? && self.end_at.present?) ? ((self.end_at - self.start_at) / 60).to_i : nil
  end
  
  def reschedule_url  # Should only be used for events with external recipient for now
    (return nil)  if self.id.blank?
    "#{SCHEDS_URL}/reschedule/#{Base64.urlsafe_encode64(self.id.to_s)}"
  end
  
  def cancel_url  # Should only be used for events with external recipient for now
    (return nil)  if self.id.blank?
    "#{SCHEDS_URL}/cancel/#{Base64.urlsafe_encode64(self.id.to_s)}"
  end
  
  def self.date_is_holiday?(date, organization, **data)
    (return nil)  if date.blank?
    r_name = data[:return_name].present?  # Optional flag to return holiday name instead of boolean
    
    # Check federal holidays first
    fed_holiday = Holidays.on(date, :us)  # Array of objects
    (return (r_name ? fed_holiday[0][:name] : true))  if fed_holiday.present?
    
    # Check "holiday" type calendar events
    time_zone = (data[:time_zone] || organization.get_time_zone)
    dt_start, dt_end = date.in_time_zone(time_zone).beginning_of_day, date.in_time_zone(time_zone).end_of_day
    ce_holiday = organization.get_calendar_events(type_of: "holiday", start_range: {start: dt_start.utc, end: dt_end.utc}).first
    
    if r_name
      ce_holiday.present? ? ce_holiday.name : nil
    else
      ce_holiday.present?
    end
  end
  
  private
  
  def create_and_send_notice_email(recipient, user, subject, message, attachment=nil)
    body_text = message.gsub("{r_fname}", recipient.first_name)
    org_id = ((recipient.is_a?(Student) || recipient.is_a?(StudentLead)) ? recipient.organization_id : user.organization_id)
    oem = OutgoingEmailMessage.create!(
      message_type: "NOTEMP", user_id: user.id, recipient_type: recipient.entity_string, recipient_id: recipient.id, to: recipient.get_email, from: user.email_send_name,
      reply_to: user.get_email, subject: subject, body_text: body_text, original_subject: subject, original_body_text: body_text, content_type: "text/html",
      attachment_url: (attachment.present? ? attachment.document.url : nil), attachment_file_name: (attachment.present? ? attachment.document_file_name : nil), organization_id: org_id)
    success, error_text, error_code = oem.send_message
    
    unless success.present? && success
      Rails.logger.info "Calendar Event Notice Email Error - [#{recipient.class.to_s rescue nil}] #{recipient.full_name rescue nil}, Success: #{success}, Error Text: #{error_text}, Error: #{error_code}"
    end
  end
  
  def create_and_send_notice_text(recipient, user, message, organization, department=nil)
    rcpt_phone = recipient.get_textable_phone_number
    (Rails.logger.info "*Phone blank for #{recipient.full_name}")  if rcpt_phone.blank?  # Skip if phone blank
    (return nil)  if rcpt_phone.blank?  # Skip if phone blank
    
    can_text = if recipient.is_a?(Student)
                 recipient.do_not_text.blank? && !DoNotTextPhone.do_not_text_phone?(organization.id, rcpt_phone)
               else
                 !DoNotTextPhone.do_not_text_phone?(organization.id, rcpt_phone)
               end
    (Rails.logger.info "*Phone on do not text for #{recipient.full_name} on #{organization.location}")  unless can_text  # Skip if phone number can't be texted
    (return nil)  unless can_text  # Skip if phone number can't be texted
    
    sms_phone = (recipient.is_a?(Student) ? recipient.most_recent_sms_phone : nil)  # Check for most recent sms phone for students
    sms_phone ||= organization.get_sms_phone("USER")  # Get from org if needed
    otm = OutgoingTextMessage.create!(
      message_type: "NOTEMP", user_id: user.id, recipient_type: recipient.entity_string, recipient_id: recipient.id, recipient_phone: rcpt_phone,
      message: (message.present? ? message.truncate(Conext::TEXT_SIZE_LIMIT) : nil), original_message: message, sms_phone: sms_phone)
    success, error_text, error_code = otm.send_message
    
    unless success.present? && success
      Rails.logger.info "Calendar Event Notice Text Error - [#{recipient.class.to_s rescue nil}] #{recipient.full_name rescue nil}#{("(Department: #{department.name})" if department.present?) rescue nil}, " +
                        "Success: #{success}, Error Text: #{error_text}, Error: #{error_code}"
    end
  end
  
end
