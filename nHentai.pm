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
        version      => "2.8",
        description  => "Downloads galleries from nHentai with Full Japanese Title support and ZIP packaging.",
        url_regex    => 'https?://nhentai\.net/g/\d+/?'
    );
}

sub provide_url {
    shift;
    my ($lrr_info, %params) = @_; 
    my $logger = get_plugin_logger();
    my $url = $lrr_info->{url};

    $logger->info("--- nHentai Mojo v2.8 Triggered: $url ---");

    # 模擬真實瀏覽器行為
    my $ua = $lrr_info->{user_agent};
    $ua->max_redirects(5);
    $ua->transactor->name('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36');

    # 1. 抓取主頁面
    my $tx = $ua->get($url);
    my $res = $tx->result;

    if ($res->is_success) {
        my $html = $res->body;
        
        # 提取完整標題 (包含 before, pretty, after)
        my $raw_title = "";
        if ($html =~ m#<h2 class="title">(.*?)</h2>#is) {
            $raw_title = $1;
        } elsif ($html =~ m#<h1 class="title">(.*?)</h1>#is) {
            $raw_title = $1;
        }
        
        my $title = "nhentai_download";
        if ($raw_title) {
            $title = $raw_title;
            $title =~ s#<[^>]*>##g; # 移除所有 HTML 標籤 (如 span)
            $title =~ s#[\r\n\t]# #g; # 將換行/製表符轉為空格
            $title =~ s#\s+# #g; # 縮減連續空格
            $title =~ s#[\/\\:\*\?"<>\|]#_#g; # 移除非法字元
            $title =~ s#^\s+|\s+$##g; # 修剪首尾空白
            
            # 限制長度，避免檔案系統報錯
            if (length($title) > 200) { $title = substr($title, 0, 200); }
        }
        
        $logger->info("Full Extracted Title: $title");

        # 提取 Media ID
        if ($html =~ m#/galleries/(\d+)/#i) {
            my $media_id = $1;
            
            # 提取總頁數
            my $num_pages = 0;
            if ($html =~ m#<span class="name">(\d+)</span>#i || $html =~ m#<div>(\d+) pages</div>#i) {
                $num_pages = $1;
            }

            if ($media_id && $num_pages > 0) {
                $logger->info("Media ID: $media_id, Pages: $num_pages");
                
                # 偵測圖片格式
                my $ext = "jpg";
                if ($html =~ m#/galleries/$media_id/1\.(png|webp|jpg)#i) { 
                    $ext = $1; 
                }

                if ($lrr_info->{tempdir}) {
                    my $work_dir = $lrr_info->{tempdir} . "/nh_$media_id";
                    unless (-d $work_dir) { mkdir $work_dir; }
                    
                    $logger->info("Downloading images to $work_dir...");
                    
                    my $downloaded = 0;
                    for (my $i = 1; $i <= $num_pages; $i++) {
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
                        return ( error => "No images downloaded." );
                    }
                }
            }
        }
    } else {
        return ( error => "nHentai access failed. code: " . $res->code );
    }

    return ( error => "Parsing failed." );
}

1;
