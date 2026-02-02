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
        version      => "2.7",
        description  => "Downloads galleries from nHentai with 403/Cloudflare mitigation and ZIP packaging.",
        url_regex    => 'https?://nhentai\.net/g/\d+/?'
    );
}

sub provide_url {
    shift;
    my ($lrr_info, %params) = @_; 
    my $logger = get_plugin_logger();
    my $url = $lrr_info->{url};

    $logger->info("--- nHentai Mojo v2.7 Triggered: $url ---");

    # 模擬真實瀏覽器行為
    my $ua = $lrr_info->{user_agent};
    $ua->max_redirects(5);
    $ua->transactor->name('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36');

    # 1. 抓取主頁面
    my $tx = $ua->get($url);
    my $res = $tx->result;

    if ($res->is_success) {
        my $html = $res->body;
        
        # 提取日文標題 (優先) 或英文標題
        my $title = "";
        if ($html =~ m#<h2 class="title">.*?<span class="pretty">(.*?)</span>#is) {
            $title = $1;
        } elsif ($html =~ m#<h1 class="title">.*?<span class="pretty">(.*?)</span>#is) {
            $title = $1;
        }
        
        if ($title) {
            $title =~ s#<[^>]*>##g; 
            $title =~ s#[/\\:*?"<>|]#_#g; 
            $title =~ s#^\s+|\s+$##g;
            if (length($title) > 150) { $title = substr($title, 0, 150); }
        } else {
            $title = "nhentai_download";
        }

        # 提取 Media ID
        if ($html =~ m#/galleries/(\d+)/#i) {
            my $media_id = $1;
            
            # 提取總頁數
            my $num_pages = 0;
            if ($html =~ m#<span class="name">(\d+)</span>#i || $html =~ m#<div>(\d+) pages</div>#i) {
                $num_pages = $1;
            }

            if ($media_id && $num_pages > 0) {
                $logger->info("Found Media ID: $media_id, Pages: $num_pages, Title: $title");
                
                # 偵測圖片格式
                my $ext = "jpg";
                if ($html =~ m#/galleries/$media_id/1\.(png|webp|jpg)#i) { $ext = $1; }

                if ($lrr_info->{tempdir}) {
                    my $work_dir = $lrr_info->{tempdir} . "/nh_$media_id";
                    unless (-d $work_dir) { mkdir $work_dir; }
                    
                    $logger->info("Downloading $num_pages images to $work_dir...");
                    
                    my $downloaded = 0;
                    for (my $i = 1; $i <= $num_pages; $i++) {
                        my $img_url = "https://i.nhentai.net/galleries/$media_id/$i.$ext";
                        my $save_to = sprintf("%s/%03d.%s", $work_dir, $i, $ext);
                        
                        # 圖片請求必須帶上正確的 Referer
                        eval {
                            my $img_tx = $ua->get($img_url => { Referer => $url });
                            if ($img_tx->result->is_success) {
                                $img_tx->result->save_to($save_to);
                                $downloaded++;
                            } else {
                                $logger->error("Failed to download image $i: " . $img_tx->result->code);
                            }
                        };
                    }

                    # 打包
                    if ($downloaded > 0) {
                        my $zip_path = $lrr_info->{tempdir} . "/$title.zip";
                        my $zip = Archive::Zip->new();
                        
                        for (my $i = 1; $i <= $num_pages; $i++) {
                            my $img_file = sprintf("%03d.%s", $i, $ext);
                            my $img_full_path = "$work_dir/$img_file";
                            if (-e $img_full_path) {
                                $zip->addFile($img_full_path, $img_file);
                            }
                        }
                        
                        if ($zip->writeToFileNamed($zip_path) == AZ_OK) {
                            $logger->info("Download and packaging complete: $zip_path");
                            return ( file_path => abs_path($zip_path) );
                        }
                    } else {
                        return ( error => "No images could be downloaded. Check IP/Rate-limit." );
                    }
                }
            }
        }
    } else {
        $logger->error("nHentai Access Error: " . $res->code . " Content: " . substr($res->body, 0, 200));
        if ($res->code == 403) {
            return ( error => "403 Forbidden: nHentai is blocking the request. Update cookies in Metadata plugin." );
        }
        return ( error => "HTTP " . $res->code );
    }

    return ( error => "Parsing failed." );
}

1;