require 'redmine'

Redmine::Plugin.register :redmine_loader do
  name 'Basic project file loader for Redmine'
  author 'Simon Stearn, Andrew Hodgkinsons, Tobias Droste'
  description 'Basic MSProject XML file loader'
  version '2.0.0'
  requires_redmine :version_or_higher => '2.0.0'

  default_tracker_id = '1'
  default_tracker_alias = 'Tracker'
  default_assigned_to_alias = 'Resource'

  settings :default => {'tracker' => default_tracker_id, 
    'tracker_alias' => default_tracker_alias,
    'assigned_to_alias' => default_assigned_to_alias,
    'custom_field_id_uid' => '0',
    'custom_field_id_resource' => '0',
    'custom_field_id_calendar_uid' => '0',
    'export_xml_header' => '',
    'export_xml_extended_attributes' => '',
    'export_xml_calendars' => '',
    'export_xml_resources' => '' }, :partial => 'settings/loader_settings'

  project_module :project_xml_importer do
    permission :import_issues_from_xml, :loader => [:new, :create]
  end

  menu :project_menu, :loader, { :controller => 'loader', :action => 'new' },
    :caption => :menu_caption, :after => :new_issue, :param => :project_id
end

