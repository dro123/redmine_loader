########################################################################
# File: loader_controler.rb # bl;a bla bla
# Hipposoft 2008 #
# #
# History: 04-Jan-2008 (ADH): Created. #
# Feb 2009 (SJS): Hacked into plugin for redmine #
########################################################################

class TaskImport
  @tasks = []
  @project_id = nil
  @new_categories = []

  attr_accessor( :tasks, :project_id, :new_categories )
end



class LoaderController < ApplicationController
  unloadable

  before_filter :find_project, :authorize, :only => [:new, :create]

  require 'zlib'
  require 'ostruct'
  require 'tempfile'
  require 'rexml/document'
  require 'builder/xmlmarkup'
  include LoaderHelper

  # This allows to update the existing task in Redmine from MS Project
  ActiveRecord::Base.lock_optimistically=false

  def initialize
    super()
    
    @ms_xml_lambda = "%Y-%m-%dT%H:%M:%S"
    
    @tracker_id = Setting["plugin_redmine_loader"]["tracker"]
    @custom_field_id_uid = Setting["plugin_redmine_loader"]["custom_field_id_uid"]
    @custom_field_id_resource = Setting["plugin_redmine_loader"]["custom_field_id_resource"]
    @custom_field_id_calendar_uid = Setting["plugin_redmine_loader"]["custom_field_id_calendar_uid"]
    @tracker_alias = Setting["plugin_redmine_loader"]['tracker_alias']
    @assigned_to_alias = Setting["plugin_redmine_loader"]['assigned_to_alias']
  end

  def missing_config

  end

  def new    
    if @custom_field_id_uid == nil || @custom_field_id_uid.to_s == "0"
      redirect_to :action => 'missing_config'
      return
    end
     
    if @custom_field_id_resource == nil || @custom_field_id_resource.to_s == "0"
      redirect_to :action => 'missing_config'
      return
    end
     
    if @custom_field_id_calendar_uid == nil || @custom_field_id_calendar_uid.to_s == "0"
      redirect_to :action => 'missing_config'
      return
    end
  end

  # Take the task data from the 'new' view form and 'create' an "import
  # session"; that is, create real Task objects based on the task list and
  # add them to the database, wrapped in a single transaction so that the
  # whole operation can be unwound in case of error.

  def create
    if @custom_field_id_uid == nil || @custom_field_id_uid.to_s == "0"
      redirect_to :action => 'missing_config'
      return
    end
     
    if @custom_field_id_resource == nil || @custom_field_id_resource.to_s == "0"
      redirect_to :action => 'missing_config'
      return
    end
     
    if @custom_field_id_calendar_uid == nil || @custom_field_id_calendar_uid.to_s == "0"
      redirect_to :action => 'missing_config'
      return
    end

    # Set up a new TaskImport session object and read the XML file details

    xmlfile = params[ :import ][ :xmlfile ]
    @import = TaskImport.new

    unless ( xmlfile.nil? )

      # The user selected a file to upload, so process it

      begin

        # We assume XML files always begin with "<" in the first byte and
        # if that's missing then it's GZip compressed. That's true in the
        # limited case of project files.

        #byte = xmlfile.getc()
        xmlfile.rewind()

        #xmlfile = Zlib::GzipReader.new( xmlfile ) #if ( byte != '<'[ 0 ] )
        xmldoc = REXML::Document.new( xmlfile.read() )
        @import.tasks, @import.new_categories = get_tasks_from_xml( xmldoc )

        if ( @import.tasks.nil? or @import.tasks.empty? )
          flash[ :error ] = l(:error_no_tasks)
        else
          flash[ :notice ] = l(:notice_task_read_successfull)
        end        

      rescue => error

        # REXML errors can be huge, including a full backtrace. It can cause
        # session cookie overflow and we don't want the user to see it. Cut
        # the message off at the first newline.

        lines = error.message.split("\n")
        line_0 = lines[0]
        flash[ :error ] = l(:error_xml_read_failed, line_0)
      end

      render :action => :new
      flash.discard( :error )
      flash.discard( :notice )

    else

      # No file was specified. If there are no tasks either, complain.

      tasks = params[ :import ][ :tasks ]

      if ( tasks.nil? )
        flash[ :error ] = l(:error_no_file_selected)
        render( { :action => :new } )
        flash.discard( :error )
        return
      end

      # Compile the form submission's task list into something that the
      # TaskImport object understands.
      #
      # Since we'll rebuild the tasks array inside @import, we can render the
      # 'new' view again and have the same task list presented to the user in
      # case of error.

      @import.tasks = []
      @import.new_categories = []
      to_import = []

      # Due to the way the form is constructed, 'task' will be a 2-element
      # array where the first element contains a string version of the index
      # at which we should store the entry and the second element contains
      # the hash describing the task itself.

      tasks.each do | taskinfo |
        index = taskinfo[ 0 ].to_i
        task = taskinfo[ 1 ]
        struct = OpenStruct.new

        struct.uid = task[ :uid ]
        struct.title = task[ :title ]
        struct.level = task[ :level ]
        struct.outlinenumber = task[ :outlinenumber ]
        struct.outnum = task[ :outnum ]
        struct.code = task[ :code ]
        struct.duration = task[ :duration ]
        struct.start = task[ :start ]
        struct.finish = task[ :finish ]
        struct.percentcomplete = task[ :percentcomplete ]
        struct.predecessors = task[ :predecessors ].split(', ')
        struct.followers = task[ :followers ].split(', ')
        struct.delays = task[ :delays ].split(', ')
        struct.category = task[ :category ]
        struct.assigned_to = task[ :assigned_to ]
        struct.parent_id = task[ :parent_id ]
        struct.notes = task[:notes]
        struct.milestone = task[:milestone]
        struct.tracker_id = task[ :tracker_id ]
        struct.resource = task[ :resource ]
        struct.calendar_uid = task[ :calendar_uid ]
        struct.new_issue = task[ :new_issue ]
        
        fill_original_issue_fields(struct)
        
        to_import[ index ] = struct if ( task[ :import ] == '1' )
      end

      to_import.compact!

      # The "import" button in the form causes token "import_selected" to be
      # set in the params hash. The "analyse" button causes nothing to be set.
      # If the user has clicked on the "analyse" button but we've reached this
      # point, then they didn't choose a new file yet *did* have a task list
      # available. That's strange, so raise an error.
      #
      # On the other hand, if the 'import' button *was* used but no tasks were
      # selected for error, raise a different error.

      if ( params[ :import ].nil? )
        flash[ :error ] = l(:error_no_new_file_selected)
      elsif ( to_import.empty? )
        flash[ :error ] = l(:error_no_tasks_selected)
      end

      # Get defaults to use for all tasks - sure there is a nicer ruby way, but this works
      #
      # Tracker
      default_tracker_id = @tracker_id
      default_tracker = Tracker.find(default_tracker_id)
      default_tracker_id = default_tracker.id

      # Bail out if we have errors to report.
      unless( flash[ :error ].nil? )
        render( { :action => :new } )
        flash.discard( :error )
        return
      end

      # We're going to keep track of new issue ID's to make dependencies work later
      uidToIssueIdMap = {}
      # keep track of new Version ID's
      uidToVersionIdMap = {}
      # keep track of the outlineNumbers to set the parent_id
      outlineNumberToIssueIDMap = {}

      # Right, good to go! Do the import.
      begin
        Issue.transaction do
          IssueRelation.transaction do
            to_import.each do | source_issue |
  
              # We comment those lines becouse they are not necesary now.
              # Add the category entry if necessary
              #category_entry = IssueCategory.find :first, :conditions => { :project_id => @project.id, :name => source_issue.category }
              logger.debug "DEBUG: Issue to be imported: #{source_issue.inspect}"
              if ( source_issue.category != "" )
                logger.debug "DEBUG: Search category id by name: #{source_issue.category}"
                category_entry = IssueCategory.find :first, :conditions => { :project_id => @project.id, :name => source_issue.category }
                logger.debug "DEBUG: Category found: #{category_entry.inspect}"
              else
                category_entry = nil
              end
  
              if (source_issue.tracker_id.to_s != "0")
                 logger.debug "DEBUG: Search tracker by id: #{source_issue.tracker_id}"
                 final_tracker = Tracker.find(source_issue.tracker_id)
                 logger.debug "DEBUG: Tracker found: #{category_entry.inspect}"
              else
                final_tracker = default_tracker;
              end
              final_tracker = default_tracker if final_tracker.nil?
  
              #if (source_issue.milestone.to_i == 0)
              destination_issue = Issue.find(:first, :conditions => ["project_id=? AND custom_values.custom_field_id=? AND custom_values.value=?", @project.id, @custom_field_id_uid.to_i, source_issue.uid], :joins => :custom_values, :readonly => false)|| Issue.new
              destination_issue.tracker_id = final_tracker.id
              destination_issue.category_id = category_entry.id unless category_entry.nil?
              destination_issue.subject = source_issue.title.slice(0, 255) # Max length of this field is 255
              destination_issue.estimated_hours = source_issue.duration
              destination_issue.project_id = @project.id
              destination_issue.author_id = User.current.id
              destination_issue.lock_version = 0
              destination_issue.done_ratio = source_issue.percentcomplete
              destination_issue.start_date = source_issue.start
              destination_issue.due_date = source_issue.finish unless source_issue.finish.nil?
              destination_issue.due_date = (Date.parse(source_issue.start, false) + ((source_issue.duration.to_f/40.0)*7.0).to_i).to_s unless destination_issue.due_date != nil
              destination_issue.description = source_issue.notes unless source_issue.notes == nil
              destination_issue.custom_field_values.collect! {|c| if c.custom_field_id == @custom_field_id_uid.to_i; c.value = Integer(source_issue.uid).to_s; end; c }
              destination_issue.custom_field_values.collect! {|c| if c.custom_field_id == @custom_field_id_resource.to_i; c.value = source_issue.resource.to_s; end; c }
              destination_issue.custom_field_values.collect! {|c| if c.custom_field_id == @custom_field_id_calendar_uid.to_i; c.value = Integer(source_issue.calendar_uid).to_s; end; c }
  
              logger.debug "DEBUG: Assigned_to field: #{source_issue.assigned_to}"
              if ( source_issue.assigned_to != "" )
                destination_issue.assigned_to_id = source_issue.assigned_to
              end
              
              if destination_issue.id != nil && destination_issue.id > 0
                # Delete all the relations off the issues that we are going to import. If they continue existing we are going to create them. If not they must be deleted.
                IssueRelation.delete_all(["issue_to_id =?", destination_issue.id])
              end
              
              destination_issue.save! unless destination_issue.nil?
  
              logger.debug "DEBUG: Issue #{destination_issue.description} imported"
              # Now that we know this issue's Redmine issue ID, save it off for later
              uidToIssueIdMap[ source_issue.uid ] = destination_issue.id
              #Save the Issue's ID with the outlineNumber as an index, to set the parent_id later
              outlineNumberToIssueIDMap[ source_issue.outlinenumber ] = destination_issue.id
              #else
              #  #If the issue is a milestone we save it as a Redmine Version
              #  version_record = Version.find(:first, :conditions => ["project_id =? AND id=?", @project.id, source_issue.uid])|| Version.new
              #  version_record.name = source_issue.title.slice(0, 59)#maximum is 60 characters
              #  version_record.description = source_issue.notes unless source_issue.notes == nil
              #  version_record.effective_date = source_issue.start
              #  version_record.project_id = @project.id
              #  version_record.save! unless version_record.nil?
              #  # Store the version_record.id  to assign the issues to the version later
              #  uidToVersionIdMap[ source_issue.uid ] = version_record.id
              #end
            end
  
            import_length = to_import.length
            flash[ :notice ] = l(:notice_import_successfull, import_length)

            # Set the parent_id. We use the outnum of the issue (the outlineNumber without the last .#).
            # This outnum is the same as the parent's outlineNumber, so we can use it as the index of the
            # outlineNumberToIssueIDMap to get the parent's ID
            
            to_import.each do | source_issue |
              destination_issue = Issue.find(:first, :conditions => ["project_id =? AND id=?", @project.id, uidToIssueIdMap[ source_issue.uid]])
              destination_issue.parent_issue_id = outlineNumberToIssueIDMap[source_issue.outnum] unless destination_issue.nil?
              destination_issue.save! unless destination_issue.nil?
            end

            # Handle all the dependencies being careful if the parent doesn't exist

            to_import.each do | source_issue |
              delaynumber = 0
              source_issue.predecessors.each do | parent_uid |
                # Parent is being imported also. Go ahead and add the association
                if ( uidToIssueIdMap.has_key?(parent_uid) )
                  # If the issue is not a milestone we have to create the issue relation
                  if (source_issue.milestone.to_i == 0)
                    relation_record = IssueRelation.new do |i|
                      i.issue_from_id = uidToIssueIdMap[parent_uid]
                      i.issue_to_id = uidToIssueIdMap[source_issue.uid]
                      i.relation_type = 'precedes'
                      # Set the delay of the relation if it exists.
                      if source_issue.delays[delaynumber] != nil
                        if source_issue.delays[delaynumber].to_i > 0
                          i.delay = (source_issue.delays[delaynumber].to_i)/4800
                          delaynumber = delaynumber + 1
                        end
                      end
                    end
                    relation_record.save!
                  else
                    # If the issue is a milestone we have to assign the predecessor to the version
                    destination_issue = Issue.find(:first, :conditions => ["project_id =? AND id=?", @project.id, uidToIssueIdMap[parent_uid]])
                    destination_issue.fixed_version_id = uidToVersionIdMap[source_issue.uid]
                    destination_issue.save!
                  end
                end
              end
              
              source_issue.followers.each do | parent_uid |
                # Parent is being imported also. Go ahead and add the association
                if ( uidToIssueIdMap.has_key?(parent_uid) )
                  # If the issue is not a milestone we have to create the issue relation
                  if (source_issue.milestone.to_i == 0)
                    relation_record = IssueRelation.new do |i|
                      i.issue_from_id = uidToIssueIdMap[parent_uid]
                      i.issue_to_id = uidToIssueIdMap[source_issue.uid]
                      i.relation_type = 'follows'
                      # Set the delay of the relation if it exists.
                      if source_issue.delays[delaynumber] != nil
                        if source_issue.delays[delaynumber].to_i > 0
                          i.delay = (source_issue.delays[delaynumber].to_i)/4800
                          delaynumber = delaynumber + 1
                        end
                      end
                    end
                    relation_record.save!
                  else
                    # If the issue is a milestone we have to assign the predecessor to the version
                    destination_issue = Issue.find(:first, :conditions => ["project_id =? AND id=?", @project.id, uidToIssueIdMap[parent_uid]])
                    destination_issue.fixed_version_id = uidToVersionIdMap[source_issue.uid]
                    destination_issue.save!
                  end
                end
              end
            end
          end
        end
        
        redirect_to( { :controller => 'issues', :action => 'index', :project_id => @project.id } )
        
        flash.discard( :error )

      rescue => error
        flash[ :error ] = l(:error_import, error.to_s)
        logger.debug "DEBUG: Unable to import tasks: #{ error }"
        render( { :action => :new } )
        flash.discard( :error )
      end
    end
  end

  def export
    find_project()
    xml, name = generate_xml
    hijack_response(xml, name)
  end

  private


  def find_project
    # @project variable must be set before calling the authorize filter
    @project = Project.find(params[:project_id])
  end


  def generate_xml
    issues = @project.issues.find(:all, :order=>"id") || []
    tracker = @project.trackers || []
    members = loaderhelp_user_selector(@project) || []
    
    xml = Builder::XmlMarkup.new( :target => out_string = "", :indent => 2 )
    xml.instruct!( :xml, :version=>"1.0", :encoding=>"UTF-8" )    
    xml_header = Setting["plugin_redmine_loader"]["export_xml_header"]
    xml_extended_attributes = Setting["plugin_redmine_loader"]["export_xml_extended_attributes"]
    xml_calendars = Setting["plugin_redmine_loader"]["export_xml_calendars"]
    xml_resources = Setting["plugin_redmine_loader"]["export_xml_resources"]
    xml_resources_root = nil
    xml_resources_root = REXML::Document.new( "<Resources>" + xml_resources + "</Resources>" ).root unless xml_resources == nil || xml_resources.empty?
    
    xml.Project("xmlns" => "http://schemas.microsoft.com/project") { |xml_project|
       xml.Name(@project.name + ".xml")
       xml_project << xml_header unless xml_header == nil || xml_header.empty?
       xml.ExtendedAttributes { |xml_ea| 
         xml_ea << xml_extended_attributes unless xml_extended_attributes == nil || xml_extended_attributes.empty?
         xml.ExtendedAttribute do
           xml.FieldID("188744015")
           xml.FieldName(@tracker_alias)
           xml.RestrictValues("1")
           xml.ValueListSortOrder("0")
           xml.ValueList do
             id = 0
             tracker.each do |t|
               id += 1
               xml.Value do
                 xml.ID(id)
                 xml.Value(t.name)
               end
             end
           end
         end
         xml.ExtendedAttribute do
           xml.FieldID("188744016")
           xml.FieldName(@assigned_to_alias)
           xml.RestrictValues("1")
           xml.ValueListSortOrder("0")
           xml.ValueList do
             id = 0
             members.each do |m|
               id += 1
               xml.Value do
                 xml.ID(id)
                 xml.Value(m[0])
               end
             end
           end
         end
       }
       xml.Calendars { |xml_cal|
         xml_cal << xml_calendars
       }
       xml.Tasks do
         xml.Task do
           xml.UID("0")
           xml.ID("0")
           xml.Name(@project.name)
           xml.Type("1")
           xml.CreateDate(@project.created_on.strftime(@ms_xml_lambda))
           xml.ConstraintType("0")
         end
         id = 0
         issues.each do |issue|
           xml.Task do
             id += 1
             uid = 0
             uid = issue.custom_field_values.select {|c| c.custom_field_id == @custom_field_id_uid.to_i } unless issue.custom_field_values == nil
             if uid == nil || uid.to_s == '' || uid.to_s == '0'
               uid = issue.id
             end
             xml.UID(uid)
             xml.ID(id)
             xml.Name(issue.subject)
             xml.Notes(issue.description)
             xml.CreateDate(issue.created_on.strftime(@ms_xml_lambda))
             xml.Priority(issue.priority_id)
             xml.Start(issue.start_date.to_time.strftime(@ms_xml_lambda))
             xml.Finish(issue.due_date.to_time.strftime(@ms_xml_lambda)) if issue.due_date
             xml.FixedCostAccrual("3")
             xml.ConstraintType("4")
             xml.ConstraintDate(issue.start_date.to_time.strftime(@ms_xml_lambda))
             calendar_uid = -1
             calendar_uid = issue.custom_field_values.select {|c| c.custom_field_id == @custom_field_id_calendar_uid.to_i } unless issue.custom_field_values == nil
             xml.CalendarUID(calendar_uid)
             #If the issue is parent: summary, critical and rollup = 1, if not = 0
             if is_parent(issue.id) == 1
               xml.Summary("1")
               xml.Critical("1")
               xml.Rollup("1")
               xml.Type("1")
             else
               xml.Summary("0")
               xml.Critical("0")
               xml.Rollup("0")
               xml.Type("0")
             end
             IssueRelation.find(:all, :include => [:issue_from, :issue_to], :conditions => ["issue_to_id =? AND relation_type IN ('follows','precedes')", issue.id]).select do |ir|
               other_issue_uid = 0
               other_issue_uid = ir.issue_from.custom_field_values.select {|c| c.custom_field_id == @custom_field_id_uid.to_i } unless ir.issue_from.custom_field_values == nil
               if other_issue_uid != nil && other_issue_uid.to_s != '' && other_issue_uid.to_s != '0'
                 xml.PredecessorLink do                 
                   xml.PredecessorUID(other_issue_uid)
                   xml.PredecessorType(ir.relation_type == 'follows' ? "2" : "1")
                   xml.CrossProject("0")
                   xml.LinkLag(ir.delay)
                   xml.LagFormat("7")
                 end
               end
             end
             #If it is a main task => WBS = id, outlineNumber = id, outlinelevel = 1
             #If not, we have to get the outlinelevel
             outlinelevel = 1
             while (issue.parent_id != nil)
               issue = @project.issues.find(:first, :conditions => ["id = ?", issue.parent_id])
               outlinelevel +=1
             end
             xml.WBS(id)
             xml.OutlineNumber(id)
             xml.OutlineLevel(outlinelevel)
             xml.ExtendedAttribute do
               xml.UID(uid)
               xml.FieldID("188744015")
               xml.Value(issue.tracker.name)
             end
             xml.ExtendedAttribute do
               xml.UID(uid)
               xml.FieldID("188744016")
               assigned_to_name = ""
               assigned_to_name = issue.assigned_to.name unless issue.assigned_to == nil
               xml.Value(assigned_to_name)
             end
           end
         end
         versions =@project.versions.find(:all, :order=>"id")
         versions.each do |version|
           xml.Task do
             id += 1
             xml.UID(version.id)
             xml.ID(id)
             xml.Name(version.name)
             xml.Notes(version.description)
             xml.CreateDate(version.created_on.strftime(@ms_xml_lambda))
             xml.Start(version.effective_date.to_time.strftime(@ms_xml_lambda))
             xml.Finish(version.effective_date.to_time.strftime(@ms_xml_lambda))
             xml.FixedCostAccrual("3")
             xml.ConstraintType("4")
             xml.ConstraintDate(version.effective_date.to_time.strftime(@ms_xml_lambda))
             issues =@project.issues.find(:all, :conditions =>["fixed_version_id=?",version.id] )
             issues.each do |issue|
               xml.PredecessorLink do
                 xml.PredecessorUID(issue.id)
               end
             end
           end
         end
       end
       xml_project << xml_resources unless xml_resources == nil || xml_resources.empty?
       # We do not assign the issue to any resource, just set the done_ratio
       xml.Assignments do
         uid = 1000
         issues.each do |issue|
           uid += 1 
           
           task_uid = 0
           task_uid = issue.custom_field_values.select {|c| c.custom_field_id == @custom_field_id_uid.to_i } unless issue.custom_field_values == nil
           
           resource_uid = 0
           resource_name = ""
           resource_tags = nil
           resource_name = issue.custom_field_values.select {|c| c.custom_field_id == @custom_field_id_resource.to_i } unless issue.custom_field_values == nil
           resource_tags = xml_resources_root.get_elements("/Resources/Resource[Name='#{resource_name}']/UID") unless xml_resources_root == nil
           resource_uid = resource_tags.first.text.to_i unless resource_tags == nil || resource_tags.length == 0

           if (task_uid != nil && task_uid.to_s != '' && task_uid.to_s != '0') && (resource_uid != nil && resource_uid.to_s != '' && resource_uid.to_s != '0')
             xml.Assignment do
               xml.UID(uid)
               xml.TaskUID(task_uid)
               xml.ResourceUID(resource_uid)
               xml.PercentWorkComplete(issue.done_ratio)
             end
           end
        end
      end
    }

    #To save the created xml with the name of the project
    projectname = @project.name + ".xml"
    return out_string, projectname
  end

  def hijack_response(out_data, projectname)
    send_data( out_data, :type => "text/xml",
    :filename => projectname )
  end

  # Look if the issue is parent of another issue or not
  def is_parent(issue_id)
    return Issue.find(:first, :conditions =>["parent_id=?", issue_id])
  end

  # Obtain a task list from the given parsed XML data (a REXML document).

  def get_tasks_from_xml( doc )

    # Extract details of every task into a flat array
    tasks = []

    logger.debug "DEBUG: BEGIN get_tasks_from_xml"

    tracker_field_id = nil;
    assigned_to_field_id = nil;

    doc.each_element( "Project/ExtendedAttributes/ExtendedAttribute[Alias='#{@tracker_alias}']/FieldID") do | ext_attr |
      tracker_field_id = ext_attr.text.to_i;
    end
    
    if tracker_field_id == nil then
      doc.each_element( "Project/ExtendedAttributes/ExtendedAttribute[FieldName='#{@tracker_alias}']/FieldID") do | ext_attr |
        tracker_field_id = ext_attr.text.to_i;
      end
    end

    doc.each_element( "Project/ExtendedAttributes/ExtendedAttribute[Alias='#{@assigned_to_alias}']/FieldID") do | ext_attr |
      assigned_to_field_id = ext_attr.text.to_i;
    end
    
    if assigned_to_field_id == nil then
      doc.each_element( "Project/ExtendedAttributes/ExtendedAttribute[FieldName='#{@assigned_to_alias}']/FieldID") do | ext_attr |
        assigned_to_field_id = ext_attr.text.to_i;
      end
    end

    doc.each_element( 'Project/Tasks/Task' ) do | task |
      begin
        logger.debug "Project/Tasks/Task found"
        struct = OpenStruct.new
        struct.level = task.get_elements( 'OutlineLevel' )[ 0 ].text.to_i unless task.get_elements( 'OutlineLevel' )[ 0 ].nil?
        struct.outlinenumber = task.get_elements('OutlineNumber')[ 0 ].text.strip unless task.get_elements('OutlineNumber')[ 0 ].nil?

        auxString = struct.outlinenumber

        index = auxString.rindex('.')
        if index != nil
          index -= 1
          struct.outnum = auxString[0..index]
        end
        struct.tid = task.get_elements( 'ID' )[ 0 ].text.to_i unless task.get_elements( 'ID'           )[ 0 ].nil?
        struct.uid = task.get_elements( 'UID' )[ 0 ].text.to_i unless task.get_elements( 'UID'          )[ 0 ].nil?
        struct.title = task.get_elements( 'Name' )[ 0 ].text.strip unless task.get_elements( 'Name'         )[ 0 ].nil?
        struct.start = task.get_elements( 'Start' )[ 0 ].text.split("T")[0] unless  task.get_elements( 'Start'        )[ 0 ].nil?
        struct.finish = task.get_elements( 'Finish' )[ 0 ].text.split("T")[0] unless task.get_elements( 'Finish')[ 0 ].nil?
        struct.calendar_uid = task.get_elements( 'CalendarUID' )[ 0 ].text.to_i unless task.get_elements( 'CalendarUID'          )[ 0 ].nil?

        s1 = task.get_elements( 'Start' )[ 0 ].text.strip unless  task.get_elements('Start')[ 0 ].nil?
        s2 = task.get_elements( 'Finish' )[ 0 ].text.strip unless  task.get_elements('Finish')[ 0 ].nil?

        struct.tracker_id = nil
        task.each_element( "ExtendedAttribute[FieldID='#{tracker_field_id}']/Value") do | tracker_value |
          if tracker_value.text != nil && !tracker_value.text.empty?
            final_tracker = Tracker.find(:first, :conditions => [ "name = ?", tracker_value.text])
            if final_tracker != nil
              struct.tracker_id = final_tracker.id;
              break
            end
          end
        end
        
        struct.assigned_to = nil
        task.each_element( "ExtendedAttribute[FieldID='#{assigned_to_field_id}']/Value") do | assigned_to_value |
          if assigned_to_value.text != nil && !assigned_to_value.text.empty?
            final_assigned_to = User.find(:first, :conditions => [ "CONCAT(firstname, ' ', lastname) = ?", assigned_to_value.text])
            if final_assigned_to
              struct.assigned_to = final_assigned_to.id;
              break
            end
          end
        end

        # If the start date and the finish date are the same it is a milestone
        if s1 == s2
          struct.milestone = 1
        else
          struct.milestone = 0
        end

        struct.percentcomplete = task.get_elements( 'PercentComplete')[0].text.to_i
        struct.notes = task.get_elements( 'Notes' )[ 0 ].text.strip unless task.get_elements( 'Notes' )[ 0 ].nil?
        struct.predecessors = []
        struct.followers = []
        struct.delays = []
        task.each_element( 'PredecessorLink' ) do | predecessor |
        begin
          predecessortype = predecessor.get_elements('Type')[0].text.to_i
          if predecessortype == 1
            struct.predecessors.push( predecessor.get_elements('PredecessorUID')[0].text.to_i )
          elsif predecessortype == 2
            struct.followers.push( predecessor.get_elements('PredecessorUID')[0].text.to_i )            
          end
          struct.delays.push( predecessor.get_elements('LinkLag')[0].text.to_i )
        end        
      end

      tasks.push( struct )
      #rescue
      rescue => error
        # Ignore errors; they tend to indicate malformed tasks, or at least,
        # XML file task entries that we do not understand.
        logger.debug "DEBUG: Unrecovered error getting tasks: #{error}"
      end
    end

    # Sort the array by ID. By sorting the array this way, the order
    # order will match the task order displayed to the user in the
    # project editor software which generated the XML file.

    tasks = tasks.sort_by { | task | task.tid }

    # Step through the sorted tasks. Each time we find one where the
    # *next* task has an outline level greater than the current task,
    # then the current task MUST be a summary. Record its name and
    # blank out the task from the array. Otherwise, use whatever
    # summary name was most recently found (if any) as a name prefix.

    all_categories = []
    category = ''

    tasks.each_index do | index |
      task = tasks[ index ]
      next_task = tasks[ index + 1 ]

      # Instead of deleting the sumary tasks I only delete the task 0 (the project)

      #if ( next_task and next_task.level > task.level )
      #  category = task.title.strip.gsub(/:$/, '') unless task.title.nil? # Kill any trailing :'s which are common in some project files
      #  all_categories.push(category) # Keep track of all categories so we know which ones might need to be added
        #tasks[ index ] = "Prueba"
      if task.level == 0
        category = task.title.strip.gsub(/:$/, '') unless task.title.nil? # Kill any trailing :'s which are common in some project files
        all_categories.push(category) # Keep track of all categories so we know which ones might need to be added
        tasks[ index ] = nil
      else
        task.category = category
      end
    end

    # Remove any 'nil' items we created above
    tasks.compact!
    tasks = tasks.uniq

    # Now create a secondary array, where the UID of any given task is
    # the array index at which it can be found. This is just to make
    # looking up tasks by UID really easy, rather than faffing around
    # with "tasks.find { | task | task.uid = <whatever> }".

    uid_tasks = []

    tasks.each do | task |      
      fill_original_issue_fields(task)
      
      uid_tasks[ task.uid ] = task
    end

    # OK, now it's time to parse the assignments into some meaningful
    # array. These will become our redmine issues. Assignments
    # which relate to empty elements in "uid_tasks" or which have zero
    # work are associated with tasks which are either summaries or
    # milestones. Ignore both types.

    real_tasks = []

    #doc.each_element( 'Project/Assignments/Assignment' ) do | as |
    #  task_uid = as.get_elements( 'TaskUID' )[ 0 ].text.to_i
    #  task = uid_tasks[ task_uid ] unless task_uid.nil?
    #  next if ( task.nil? )

    #  work = as.get_elements( 'Work' )[ 0 ].text
      # Parse the "Work" string: "PT<num>H<num>M<num>S", but with some
      # leniency to allow any data before or after the H/M/S stuff.
    #  hours = 0
    #  mins = 0
    #  secs = 0

    #  strs = work.scan(/.*?(\d+)H(\d+)M(\d+)S.*?/).flatten unless work.nil?
    #  hours, mins, secs = strs.map { | str | str.to_i } unless strs.nil?

      #next if ( hours == 0 and mins == 0 and secs == 0 )

      # Woohoo, real task!

    #  task.duration = ( ( ( hours * 3600 ) + ( mins * 60 ) + secs ) / 3600 ).prec_f

    #  real_tasks.push( task )
    #end

    set_assignment_to_task(doc,uid_tasks)

    logger.debug "DEBUG: Real tasks: #{real_tasks.inspect}"
    logger.debug "DEBUG: Tasks: #{tasks.inspect}"

    real_tasks = tasks if real_tasks.empty?

    real_tasks = real_tasks.uniq unless real_tasks.nil?
    all_categories = all_categories.uniq.sort

    logger.debug "DEBUG: END get_tasks_from_xml"

    return real_tasks, all_categories
  end
  
  def fill_original_issue_fields(task)
    issue = Issue.find(:first, :conditions => ["project_id=? AND custom_values.custom_field_id=? AND custom_values.value=?", @project.id, @custom_field_id_uid.to_i, task.uid], :joins => :custom_values)
          
    task.new_issue = issue == nil
    
    if issue == nil
      return
    end
            
    if task.tracker_id == nil || task.tracker_id == 0
      task.tracker_id = issue.tracker_id
    end        
    if (task.assigned_to == nil || task.assigned_to == 0) && issue.assigned_to != nil
      task.assigned_to = issue.assigned_to.id
    end
    
    task.orig_title = issue.subject
    task.orig_duration = issue.duration
    task.orig_start = issue.start_date
    task.orig_finish = issue.due_date
    task.orig_percentcomplete = issue.done_ratio
    task.orig_assigned_to = issue.assigned_to_id
    task.orig_tracker_id = issue.tracker_id
    task.orig_resource = issue.custom_field_values.select {|c| c.custom_field_id == @custom_field_id_resource.to_i } unless issue.custom_field_values == nil
    task.orig_calendar_uid = issue.custom_field_values.select {|c| c.custom_field_id == @custom_field_id_calendar_uid.to_i } unless issue.custom_field_values == nil
  end

  NOT_USER_ASSIGNED = -65535

  def set_assignment_to_task(doc,uid_tasks)
    resources = get_resources(doc)

    doc.each_element( 'Project/Assignments/Assignment' ) do | as |
      task_uid = as.get_elements( 'TaskUID' ).first.text.to_i
      task = uid_tasks[ task_uid ] unless task_uid.nil?
      next if ( task.nil? )

      resource_id = as.get_elements('ResourceUID').first.text.to_i
      next if (resource_id == NOT_USER_ASSIGNED)

      task.resource = resources[resource_id]
    end

  end

  def get_bind_resource_users(doc)    
    resources = get_resources(doc)
    users_list = get_user_list_for_project()

    users_list.sort_by { |user| user.login }

    resource_by_user = []

    resources.each do |uid,name|
      user_found = users_list.find_all { |user| user.login == name }
      next if (user_found.first.nil?)
      resource_by_user[uid] = user_found.first.id
    end
    
    return resource_by_user

  end

  def get_user_list_for_project()
    memberList = Member.find( :all, :conditions => { :project_id => @project.id } )

    userList = []
    
    memberList.each do | current_member |
      userList.push( User.find( :first, :conditions => { :id => current_member.user_id } ) )
    end

    return userList    
  end

  def get_resources(doc)
    
    resources = {}

    doc.each_element( 'Project/Resources/Resource' ) do | as |      
      resource_uid = as.get_elements('UID').first.text.to_i
      resource_name_element = as.get_elements('Name').first;      
      
      next if (resource_uid == 0 or resource_name_element.nil?)

      resources[resource_uid] = resource_name_element.text
    end

    return resources

  end

end
