#
# Cookbook:: instiki for SUSE.
# Recipe:: default
#
# Copyright:: 2018, The Authors, All Rights Reserved.

if node['platform_version'] == '42.3'

	zypper_repository 'devel:languages:ruby:extensions' do
		baseurl 'https://download.opensuse.org'
		path '/repositories/devel:languages:ruby:extensions/openSUSE_Leap_42.3/'
		autorefresh true
		gpgcheck false
		repo_name 'devel:languages:ruby:extensions'
	end

end

package 'gcc'
package 'glibc-devel'
package 'make'

directory '/tmp/.instiki_installer' do
	user node['host']['user']
	group node['host']['group']
	mode 00755
	action :create
end

remote_file '/tmp/.instiki_installer/libiconv-1.15.tar.gz' do
	source 'https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.15.tar.gz'
	action :create_if_missing
end

execute 'extract libiconv tarball' do
	command 'tar xzvf libiconv-1.15.tar.gz'
	cwd '/tmp/.instiki_installer/'
	not_if { File.directory?("/tmp/.libiconv/libiconv-1.15") }
end

bash 'make and install libiconv' do
	cwd '/tmp/.instiki_installer/libiconv-1.15'
	not_if { File.file?("/usr/local/lib64/libiconv.so") }
	code <<-EOH
./configure
make
make install
EOH
end

package 'ruby2.3'
package 'ruby2.3-devel'
package 'ruby2.3-rubygem-RedCloth'
package 'ruby2.3-rubygem-bundler'
package 'ruby2.3-rubygem-eventmachine'
package 'ruby2.3-rubygem-sqlite3'
package 'zlib-devel'
package 'ruby2.3-rubygem-pg'
package 'postgresql-devel'
package 'libxslt1'
package 'libcap-progs'

user_name = node['host']['user']
group_name = node['host']['group']
home_dir = "/home/#{node['host']['user']}"

decrypt_info = Chef::EncryptedDataBagItem.load('our_postgres', 'postgres')

psql_info = {
	:psql_user => decrypt_info['user'],
	:psql_passwd => decrypt_info['passwd'],
	:psql_host => decrypt_info['host'],
	:psql_port => decrypt_info['port']
}

git "#{home_dir}/instiki" do
	repository 'https://github.com/parasew/instiki'
	revision 'master'
	action :checkout
	user user_name
	group group_name
	environment({
		'USER' => user_name,
		'HOME' => home_dir
	})
end

template "#{home_dir}/instiki/config/database.yml" do
	source 'home/instiki/config/database.yml.erb'
	action :create
	variables(psql_info)
	user user_name 
	group group_name
end

execute 'bundle install' do
	command 'bundle install'
	cwd "#{home_dir}/instiki"
	user user_name
	environment({
		'USER' => user_name,
		'HOME' => home_dir
	})
end

template "#{home_dir}/instiki/Gemfile" do
	source 'home/instiki/Gemfile'
	action :create
	user user_name
	group group_name 
end

template "#{home_dir}/.pgpass" do
	source 'home/.pgpass.erb'
	action :create
	user user_name
	group group_name
	mode 00600
	variables(psql_info)
end

## the property 'AmbientCapabilities = CAP_NET_BIND_SERVICE=+eip' and 'NoNewPrivileges = true' of the Systemd is same effect. However, this property introduced until Systemd v229.
execute "the setting of port80 binding for non privilege user" do
	command "setcap 'cap_net_bind_service=+ep' /usr/bin/ruby.ruby2.3"
end

if node.chef_environment == 'development'

	package 'postgresql'
	package 'sqlite3'

	bash "convert sqlite3 db to postgresql db" do
		user user_name
		code <<-EOF
			sqlite3 #{home_dir}/instiki/db/production.db.sqlite3 .dump > $TMP_DUMP_FILE
			
			sed -i '/PRAGMA/d' $TMP_DUMP_FILE
			sed -i 's/AUTOINCREMENT //g' $TMP_DUMP_FILE
			sed -i '/sqlite_sequence/d ; s/INTEGER PRIMARY KEY/SERIAL PRIMARY KEY/ig' $TMP_DUMP_FILE
			sed -i 's/datetime/timestamp/g' $TMP_DUMP_FILE
			sed -i -r 's/integer\\([^\\)]*\\)/integer/g' $TMP_DUMP_FILE
			sed -i -r 's/text\\(([0-9]+)\\)/varchar\\(\\1\\)/g' $TMP_DUMP_FILE 
			sed -i 's/TINYINT/INTEGER/g' $TMP_DUMP_FILE
			sed -i -r 's/varchar\\([1-9][0-9]\{7,\}\\)/varchar\\(10485760\\)/g' $TMP_DUMP_FILE
		EOF
		environment({
			'USER' => user_name,
			'HOME' => home_dir,
			'TMP_DUMP_FILE' => "#{home_dir}/instiki/db/production.db.psql"
		})
	end

	bash 'store db to postgres' do
		user user_name
		code <<-EOF
		
			dropdb -U #{decrypt_info['user']} -h #{decrypt_info['host']} instiki_production
			createdb --encoding=UTF8 -T template0 --lc-collate=C --lc-ctype=C -U #{decrypt_info['user']} -h #{decrypt_info['host']} instiki_production
			psql -U #{decrypt_info['user']} -d instiki_production -h #{decrypt_info['host']} < $TMP_DUMP_FILE

			psql -U #{decrypt_info['user']} -d instiki_production -h #{decrypt_info['host']} -c "\ds" | grep sequence | cut -d'|' -f2 | tr -d '[:blank:]' |
			while read sequence_name; do
				table_name=${sequence_name%_id_seq}

				psql -U #{decrypt_info['user']} -d instiki_production -h #{decrypt_info['host']} -c "select setval('$sequence_name', (select max(id) from $table_name))"
			done
		EOF
		environment({
			'USER' => user_name,
			'HOME' => home_dir,
			'TMP_DUMP_FILE' => "#{home_dir}/instiki/db/production.db.psql"
		})
	end

	package 'sqlite3' do
		action :remove
	end

	package 'postgresql' do
		action :remove
	end

end

systemd_unit 'instiki.service' do
	content(Unit: {
			Description: 'Instiki daemon',
			After: 'network.target'
		},
		Service: {
			WorkingDirectory: "#{home_dir}/instiki",
			ExecStart: '/usr/bin/bundler.ruby2.3 exec instiki -e production --port=80',
			Restart: 'always',
			Type: 'simple',
			User: user_name,
			Group: group_name
		},
		Install: {
			WantedBy: 'multi-user.target'
		})
	action [:create, :enable, :start]
end
