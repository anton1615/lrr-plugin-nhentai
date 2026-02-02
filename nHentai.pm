package LANraragi::Plugin::Download::nHentai;

use strict;
use warnings;
no warnings 'uninitialized';

# 確保在容器環境內能找到 LRR 的核心模組
use lib '/home/koyomi/lanraragi/lib';
use LANraragi::Utils::Logging qw(get_plugin_logger);
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use File::Temp qw(tempfile);
use Cwd 'abs_path';

sub plugin_info {
    return (
        name         => "nHentai Downloader",
        type         => "download",
        namespace    => "nhdl",
        author       => "Gemini CLI",
        version      => "3.0",
        description  => "High-quality nHentai downloader with robust metadata parsing and ZIP packaging.",
        url_regex    => 'https?://nhentai\.net/g/\d+/?'
    );
}

sub provide_url {
    shift;
    my ($lrr_info, %params) = @_; 
    my $logger = get_plugin_logger();
    my $url = $lrr_info->{url};

    $logger->info("--- nHentai Mojo v3.0 Triggered: $url ---");

    # 模擬真實瀏覽器
    my $ua = $lrr_info->{user_agent};
    $ua->max_redirects(5);
    $ua->transactor->name('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36');

    my $tx = $ua->get($url);
    my $res = $tx->result;

    if ($res->is_success) {
        my $html = $res->body;
        
        # 1. 提取完整日文標題
        my $raw_title = "";
        if ($html =~ m#<h2 class="title">(.*?)</h2>#is) { $raw_title = $1; }
elsif ($html =~ m#<h1 class="title">(.*?)</h1>#is) { $raw_title = $1; }
        
        my $title = "nhentai_download";
        if ($raw_title) {
            $title = $raw_title;
            $title =~ s#<[^>]*>##g; 
            $title =~ s#[/\\:*?"<>|]#_#g; 
            $title =~ s#\s+# #g;
            $title =~ s#^\s+|\s+$##g;
            if (length($title) > 150) { $title = substr($title, 0, 150); }
        }

        # 2. 獲取 Media ID
        my $media_id = "";
        if ($html =~ m#/galleries/(\d+)/#i) { $media_id = $1; }

        # 3. 獲取圖片格式與總頁數 (混合模式)
        my @page_exts;
        
        # 嘗試從 JSON 抓取 (最精準)
        if ($html =~ m#images["']\s*:\s*\{["']pages["']\s*:\s*\[(.*?)\]#is) {
            my $pages_json = $1;
            while ($pages_json =~ m#["']t["']\s*:\s*["']([pjw])["']#g) {
                push @page_exts, ($1 eq 'p' ? "png" : ($1 eq 'w' ? "webp" : "jpg"));
            }
        }

        # 備援：從 HTML 掃描縮圖格式
        if (scalar @page_exts == 0) {
            $logger->info("Falling back to HTML thumbnail scanning...");
            my $default_ext = "jpg";
            if ($html =~ m#/galleries/$media_id/1t\.(png|webp|jpg)#i) { $default_ext = $1; }
            
            my $num_pages = 0;
            if ($html =~ m#<span class="name">(\d+)</span>#i || $html =~ m#(\d+)\s+pages#i) { $num_pages = $1; }
            
            for (my $i = 0; $i < $num_pages; $i++) { push @page_exts, $default_ext; }
        }

        if ($media_id && scalar @page_exts > 0) {
            my $num_pages = scalar @page_exts;
            $logger->info("Media ID: $media_id, Pages: $num_pages, Format: $page_exts[0]");

            if ($lrr_info->{tempdir}) {
                my $work_dir = $lrr_info->{tempdir} . "/nh_$media_id";
                mkdir $work_dir;
                
                my $downloaded = 0;
                for (my $i = 1; $i <= $num_pages; $i++) {
                    my $ext = $page_exts[$i-1];
                    my $img_url = "https://i.nhentai.net/galleries/$media_id/$i.$ext";
                    my $save_to = sprintf("%s/%03d.%s", $work_dir, $i, $ext);
                    
                    eval {
                        my $img_tx = $ua->get($img_url => { Referer => $url });
                        if ($img_tx->result->is_success) {
                            $img_tx->result->save_to($save_to);
                            $downloaded++;
                        }
                    };
                }

                if ($downloaded > 0) {
                    my $zip_path = $lrr_info->{tempdir} . "/$title.zip";
                    my $zip = Archive::Zip->new();
                    for (my $i = 1; $i <= $num_pages; $i++) {
                        my $ext = $page_exts[$i-1];
                        my $img_file = sprintf("%03d.%s", $i, $ext);
                        my $path = "$work_dir/$img_file";
                        if (-e $path) { $zip->addFile($path, $img_file); }
                    }
                    $zip->writeToFileNamed($zip_path);
                    return ( file_path => abs_path($zip_path) );
                }
            }
        }
    }
    return ( error => "nHentai parsing failed. (v3.0)" );
}

1;
