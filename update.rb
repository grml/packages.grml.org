#!/usr/bin/env ruby
require 'git'
require 'erb'
require 'yaml'
require 'net/http'
require 'uri'
require 'zlib'
require 'yaml'

def build_used_package_list(source_files)
  source_files.map do |source_file|
    File.read(source_file).split("\n").reject do |l|
      l.strip.start_with?('#') or l.strip == ""
    end
  end.flatten
end

def parse_debian_sources(data)
  data.split("\n").push('').inject({}) do |pkgs, l|
    l.rstrip!
    pkg = pkgs[:_tmp] || {}
    if pkg[:_tmp]
      if l[0..0] == ' '
	pkg[:_tmp][:data] << l.strip
      else
	pkg[pkg[:_tmp][:hdr]] = pkg[:_tmp][:data].compact
	pkg.delete :_tmp
      end
    end
    unless pkg[:_tmp]
      if l == '':
	pkgs[pkg['Package'][0]] = pkg
	pkg = nil
      else
	hdr, data = l.strip.split(':', 2)
	data.strip! unless data.nil?
	pkg[:_tmp] = {:hdr => hdr, :data => [data]}
      end
    end
    if pkg.nil?
      pkgs.delete :_tmp
    else
      pkgs[:_tmp] = pkg
    end
    pkgs
  end
end

def build_package_list(packages, used, sources)
  data = {}
  packages.each do |pkg|
    next if not File.exists?(File.join(pkg, 'debian'))
    begin
      g = Git.open(working_dir = pkg)
      #g.pull(Git::Repo, Git::Branch) # fetch and a merge
    rescue ArgumentError
      g = Git.bare(working_dir = pkg)
    end

    current_head = g.gcommit('HEAD')
    next if not current_head.parent

    p = {
      :head_is_tagged => false,
      :used => {},
      :name => pkg,
      :version => nil,
      :has_tags => false,
      :version_in_repo => nil
    }
    used.each do |dist,l|
      p[:used][dist] = l.include?(pkg)
    end
    if sources[pkg]
      p[:version_in_repo] = sources[pkg]['Version'][0]
    end

    for tag in g.tags.reverse
      p[:has_tags] = true
      t = g.gcommit(tag.name)
      next if not t.parent
      #$stderr.puts "#{pkg}: Checking tag #{tag.name}: tag parent: #{t.parent.sha} HEAD: #{current_head.parent.sha}"
      if t.parent.sha === current_head.parent.sha
        p[:head_is_tagged] = true
        p[:version] = tag.name
        break
      end
    end

    data[pkg] = p
  end
  data
end

def fetch_file(uri)
  response = Net::HTTP.get_response(URI.parse(uri))
  body = response.body
  if uri.match(/\.gz$/)
    body = Zlib::GzipReader.new(StringIO.new(body.to_s)).read
  end
  body
end

template = ERB.new <<-EOF
<!doctype html>
<head>
  <meta charset="utf-8">
  <title>Grml.org Package Index</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header>
  <h1>All Grml packages</h1>
  <p>Last update: <%= Time.now.to_s %></p>
  </header>
  <div id="main">
  <table>
  <tr>
  <th>Package</th><th>Git</th><th>Download</th><th>Fresh?</th><th>grml-testing</th><th>In FULL?</th>
  </tr>
  <% packages.keys.sort.each do |pn|
  p = packages[pn]
  %>
  <tr>
  <td><%= p[:name] %></td>
  <td class="git"><a href="http://git.grml.org/?p=<%= p[:name] %>.git;a=summary">Git</a></td>
  <td class="download">
    <% if p[:has_tags] %>
    <a href="http://deb.grml.org/pool/main/<%= p[:name][0..0] %>/<%= p[:name] %>/">Download</a>
    <% end %>
  </td>
  <% if p[:head_is_tagged] %>
  <td class="ok">Version <%= p[:version] %></td>
  <% else %>
  <td class="error <% if p[:used][:full] %>important<% end %>">Untagged changes</td>
  <% end %>
  <td><%= p[:version_in_repo] || "" %></td>
  <td class="installed"><%= p[:used][:full] ? "Yes" : "No" %></td>
  </tr>
  <% end %>
  </table>
  </div>
  <footer>
  </footer>
</body>
</html>
EOF

used_packages = {
  :full => build_used_package_list(['grml-live/etc/grml/fai/config/package_config/GRMLBASE', 'grml-live/etc/grml/fai/config/package_config/GRML_FULL']),
}
sources = parse_debian_sources(fetch_file('http://deb.grml.org/dists/grml-testing/main/source/Sources.gz'))

packages = build_package_list(ARGV, used_packages, sources)

File.open('index.html.new','w') do |f|
  f.write template.result(binding)
end
File.open('packages.yaml.new','w') do |f|
  f.write packages.to_yaml
end

FileUtils.mv 'index.html.new', 'index.html'
FileUtils.mv 'packages.yaml.new', 'packages.yaml'

