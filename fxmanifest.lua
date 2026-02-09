fx_version 'cerulean'
game 'gta5'

lua54 'yes'

shared_scripts {
  '@ox_lib/init.lua',
  '@lation_ui/init.lua',
  'config.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server.lua',
  'sv_config.lua',
}

client_scripts {
  'client.lua',
}

dependency 'ox_lib'
dependency 'ox_inventory'
