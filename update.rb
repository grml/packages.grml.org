#!/usr/bin/env ruby
require 'git'
require 'erb'
require 'yaml'
require 'net/http'
require 'uri'
require 'zlib'
require 'yaml'

DEBUG = true

def build_used_package_list(source_uri)
  source_uri.map do |source_uri|
    fetch_file(source_uri).split("\n").reject do |l|
      l.strip.start_with?('#') or l.strip == ""
    end
  end.flatten
end

def parse_debian_sources(data)
  data.split("\n").push('').inject({}) do |pkgs, l|
    l.rstrip!
    pkg = pkgs[:_tmp] || {}
    if pkg[:_tmp]
      if l[0..0] == ' ' then
	pkg[:_tmp][:data] << l.strip
      else
	pkg[pkg[:_tmp][:hdr]] = pkg[:_tmp][:data].compact
	pkg.delete :_tmp
      end
    end
    unless pkg[:_tmp]
      if l == '' then
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

def build_package_list(repos, used, sources)
  data = {}
  (repos.keys + sources.keys).each do |pkg|
    p = {
      :problem => nil,
      :used => {},
      :name => pkg,
      :git_version => nil,
      :has_tags => false,
      :repo_version => nil,
    }

    puts "I: inspecting git repo #{repos[pkg]}" if DEBUG
    begin
      g = Git.bare(working_dir = repos[pkg])
      tree = g.ls_tree('HEAD')["tree"]
      if pkg == 'grml-kernel'
        tree = g.ls_tree(g.ls_tree("HEAD")["tree"]["linux-3"][:sha])["tree"]
      end
      current_head = g.gcommit('HEAD')
      raise "no head" if not current_head.parent
      raise "no debian dir in git" if not tree.keys.include?("debian")
      p.merge!({
        :git_browser => "https://github.com/grml/%s" % pkg,
        :git_anon => "https://github.com/grml/%s.git" % pkg,
      })
    rescue Exception => error
      puts "E: inspecting git repo #{repos[pkg]} failed: #{error}"
    end

    used.each do |dist,l|
      p[:used][dist] = l.include?(pkg)
    end
    if sources[pkg]
      p.merge!({
        :repo_url => "https://deb.grml.org/pool/main/%s/%s/" % [sources[pkg]['Package'][0][0..0], sources[pkg]['Package'][0]],
        :repo_version => sources[pkg]['Version'][0],
        :source_name => sources[pkg]['Package'][0],
      })
    end

    if p[:git_anon]
      head_is_tagged = false
      for tag in g.tags.reverse
        p[:has_tags] = true
        t = g.gcommit(tag.name)
        next if not t.parent
        #$stderr.puts "#{pkg}: Checking tag #{tag.name}: tag parent: #{t.parent.sha} HEAD: #{current_head.parent.sha}"
        if t.parent.sha === current_head.parent.sha
          head_is_tagged = true
          p[:git_version] = tag.name.gsub('%', ':')
          break
        end
      end
      if !head_is_tagged
        p[:problem] = 'Untagged changes'
      end
    else
      p[:problem] = 'Unknown (Missing checkout)'
    end

    if !p[:problem]
      if p[:git_version] and p[:repo_version]
        repo_version = p[:repo_version].gsub('~','_')
        if (p[:git_version] != repo_version) and (p[:git_version] != 'v'+repo_version)
          p[:problem] = 'Git/Repo not in sync'
        end
      end
    end

    puts "I: current_head=#{if current_head then current_head.sha else "nil" end} p=#{p}" if DEBUG
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

def update_git_repos(git_repos)
  git_repos.each do |name, path|
    # fix git remote config if needed
    out = %x{cd #{path} && git config remote.origin.fetch 'refs/heads/*:refs/heads/*'}
    out = %x{cd #{path} && git remote update --prune 2>&1 && git fetch --all --tags 2>&1}
    puts "#{name}: " + out if DEBUG
  end
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
  </header>
  <div id="main">
  <table>
  <tr>
  <th>Package</th><th>Git</th><th>Download</th><th>Status</th><th>Git</th><th>grml-testing</th><th>In FULL?</th>
  </tr>
  <% packages.keys.sort.each do |pn|
  p = packages[pn]
  %>
  <tr>
  <td><%= p[:name] %></td>
  <td class="git"><% if p[:git_browser] %><a href="<%= p[:git_browser] %>">Git</a><% end %></td>
  <td class="download"><% if p[:repo_url] %><a href="<%= p[:repo_url] %>">Download</a><% end %></td>
  <% if !p[:problem] %>
  <td class="ok">Pass</td>
  <% else %>
  <td class="error <% if p[:used][:full] %>important<% end %>"><%= p[:problem] %></td>
  <% end %>
  <td><%= p[:git_version] || "??" %></td>
  <td><%= p[:repo_version] || "" %></td>
  <td class="installed"><%= p[:used][:full] ? "Yes" : "No" %></td>
  </tr>
  <% end %>
  </table>
  </div>
  <div>
  </div>
  <footer>
  <p>Last update: <%= Time.now.to_s %></p>
  </footer>
</body>
</html>
EOF

used_packages = {
  :full => build_used_package_list([
                                    'https://raw.githubusercontent.com/grml/grml-live/master/etc/grml/fai/config/package_config/GRMLBASE',
                                    'https://raw.githubusercontent.com/grml/grml-live/master/etc/grml/fai/config/package_config/GRML_FULL',
                                   ]),
}
sources = {}
parse_debian_sources(fetch_file('https://deb.grml.org/dists/grml-testing/main/source/Sources.gz')).each do |k,v|
  if v['Vcs-Git'] and v['Vcs-Git'][0]
    if m = v['Vcs-Git'][0].match('github.com/grml\/(.*).git$') then
      k = m[1]
    elsif m = v['Vcs-Git'][0].match('git.grml.org\/(.*).git$') then
      k = m[1]
    end
  end
  sources[k] = v
end

git_repos = Hash[*(Dir.glob('git/*.git').map do |p| [File.basename(p, '.git'), p] end.flatten)]

update_git_repos git_repos

packages = build_package_list(git_repos, used_packages, sources)

File.open('htdocs/index.html.new','w') do |f|
  f.write template.result(binding)
end
File.open('htdocs/packages.yaml.new','w') do |f|
  f.write packages.to_yaml
end

FileUtils.mv 'htdocs/index.html.new', 'htdocs/index.html'
FileUtils.mv 'htdocs/packages.yaml.new', 'htdocs/packages.yaml'
