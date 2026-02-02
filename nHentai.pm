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
        version      => "2.6",
        description  => "Downloads galleries from nHentai with Japanese Title support and ZIP packaging.",
        url_regex    => 'https?://nhentai\.net/g/\d+/?'
    );
}

sub provide_url {
    shift;
    my ($lrr_info, %params) = @_; 
    my $logger = get_plugin_logger();
    my $url = $lrr_info->{url};

    $logger->info("--- nHentai Mojo v2.6 Triggered: $url ---");

    # 使用 LRR 提供的 UserAgent (含 Cookies)
    my $ua = $lrr_info->{user_agent};
    $ua->max_redirects(5);

    my $tx = $ua->get($url);
    my $res = $tx->result;

    if ($res->is_success) {
        my $html = $res->body;
        
        # 1. 優先提取日文標題 (通常在 h2.title)
        my $title = "";
        if ($html =~ m#<h2 class="title">.*?<span class="pretty">(.*?)</span>#is) {
            $title = $1;
        } elsif ($html =~ m#<h1 class="title">.*?<span class="pretty">(.*?)</span>#is) {
            # 如果沒日文標題，回退到英文標題
            $title = $1;
        }
        
        # 清理標題 (安全性強化)
        if ($title) {
            $title =~ s#<[^>]*>##g; # 移除 HTML
            $title =~ s#[/\\:*?"<>|]#_#g; # 移除非法字元
            $title =~ s#^\s+|\s+$##g; # 修剪空白
            if (length($title) > 150) { $title = substr($title, 0, 150); }
        } else {
            $title = "nhentai_download";
        }

        # 2. 提取 Media ID
        if ($html =~ m#/galleries/(\d+)/#i) {
            my $media_id = $1;
            
            # 3. 提取總頁數
            my $num_pages = 0;
            if ($html =~ m#<span class="name">(\d+)</span>#i || $html =~ m#<div>(\d+) pages</div>#i) {
                $num_pages = $1;
            }

            if ($media_id && $num_pages > 0) {
                $logger->info("Found Media ID: $media_id, Pages: $num_pages, JP Title: $title");
                
                # 偵測圖片格式
                my $ext = "jpg";
                if ($html =~ m#/galleries/$media_id/1\.(png|webp|jpg)#i) { 
                    $ext = $1; 
                }

                if ($lrr_info->{tempdir}) {
                    # 建立暫存下載目錄
                    my $work_dir = $lrr_info->{tempdir} . "/nh_$media_id";
                    unless (-d $work_dir) { mkdir $work_dir; }
                    
                    $logger->info("Downloading $num_pages images to $work_dir...");
                    
                    for (my $i = 1; $i <= $num_pages; $i++) {
                        my $img_url = "https://i.nhentai.net/galleries/$media_id/$i.$ext";
                        my $save_to = sprintf("%s/%03d.%s", $work_dir, $i, $ext);
                        eval {
                            $ua->get($img_url)->result->save_to($save_to);
                        };
                        if ($@) {
                            $logger->error("Image $i download failed: $@");
                        }
                    }

                    # 建立 ZIP (檔名使用日文標題)
                    my $zip_path = $lrr_info->{tempdir} . "/$title.zip";
                    my $zip = Archive::Zip->new();
                    
                    $logger->info("Packaging images into $zip_path...");
                    
                    my $added = 0;
                    for (my $i = 1; $i <= $num_pages; $i++) {
                        my $img_file = sprintf("%03d.%s", $i, $ext);
                        my $img_full_path = "$work_dir/$img_file";
                        if (-e $img_full_path && -s $img_full_path) {
                            $zip->addFile($img_full_path, $img_file);
                            $added++;
                        }
                    }
                    
                    if ($added > 0) {
                        unless ($zip->writeToFileNamed($zip_path) == AZ_OK) {
                            $logger->error("Archive::Zip failed to write to $zip_path");
                            return ( error => "Packaging failed." );
                        }
                        
                        if (-s $zip_path) {
                            $logger->info("Download successful: $zip_path");
                            return ( file_path => abs_path($zip_path) );
                        }
                    } else {
                        return ( error => "No images were downloaded." );
                    }
                }
            }
        }
    } else {
        $logger->error("Access failed code: " . $res->code);
        return ( error => "nHentai access failed. code: " . $res->code );
    }

    return ( error => "Could not parse nHentai content." );
}

1;
