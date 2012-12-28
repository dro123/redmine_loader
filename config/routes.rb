if Rails::VERSION::MAJOR >= 3
  match 'projects/:project_id/redmine_loader/new', :to => 'loader#new'
  match 'projects/:project_id/redmine_loader/create', :to => 'loader#create'
  match 'projects/:project_id/redmine_loader/export', :to => 'loader#export'
  match 'projects/:project_id/redmine_loader/missing_config', :to => 'loader#missing_config'
else
  ActionController::Routing::Routes.draw do |map|
    map.connect 'projects/:project_id/redmine_loader/:action', :controller => 'loader'
  end
end