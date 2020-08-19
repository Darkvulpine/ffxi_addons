-- アドオン情報設定
_addon.name		= 'TargetBar'
_addon.author	= 'dsw'
_addon.version	= '2020-06-08'
_addon.language	= 'japanese'
_addon.command  = 'targetbar'
_addon.commands = { 'tb' }

-----------------------------------------------------------------------

-- パッケージ追加
local Config = require( 'config' )
local Packets = require( 'packets' )
local Resources = require( 'resources' )

-- パケット種別
local LOGIN_ZONE 			= 0x0A
local LOGOUT_ZONE			= 0x0B
local ACTION				= 0x28
local ACTION_MESSAGE		= 0x29

local WIDE_SCAN 			= 0xF4

local CUTSCENE_STATUS_ID	= 4

-----------------------------------------------------------------------

-- 設定情報の読み込み
local Defaults = require( 'settings' )
local Settings = Config.load( Defaults )

local Nms    	= require( 'nms' )
local Spells    = require( 'spells' )
local Abilities = require( 'abilities' )
local Skills    = require( 'skills' )

-----------------------------------------------------------------------

-- ＵＩ定義
local UI = require( 'ui' )

-----------------------------------------------------------------------

local addon =
{
	-- フィールド変数(protected想定/実際はpublic)
	isLogin		= false,
	isZoning	= false,		-- ゾーン内にいるかどうか
	isCutscene	= false,		-- カットシーン中かどうか
	isDisplay	= false,

	-----------------------------------------------------------

	visible = false,

	-- ターゲットのインスタンスは参照が使い回されてしまうため表示状態の判定には使えない
	mtVisible = false,
	mtVisible = false,
	
	-- 現在のターゲット
	mTarget = nil,
	sTarget = nil,

	-- レベルを保持するリスト
	levelTable = nil,
	levelTableWorks = nil,

	-- バフ効果の管理対象ゾーンチェンジで必ずクリアすること
	effectiveTargets = nil,

	-- スキャン間隔(デフォルトは30秒)
	lastScanningTime = 0,

	isPlayerPosition = false,
	playerPosition = { X = 0, Y = 0 },

	scanningUpdateTime = 0,
	scanningActiveTime = 0,

	-- アイテム情報を全て取得完了(ゾーンチェンジが完全に完了した判定に使用する)
	finishInventoy = false,

	-------------------------------------------------------------------

	-- スクリプトのロード完了後に行う処理(通常起動の場合はログイン前であるためセーブは使えない)
	Prepare = function( this )
		this.isLogin    = false
		this.isZoning   = false
		this.isCutscene = false
		this.isDisplay  = false
		this.isAwake    = false

		UI:Load( Settings )
	end,

	Destroy = function( this )
		UI:Hide()

		this.effectiveTargets = nil
		this.levelTableWorks = nil
		this.levelTable = nil

		this.isAwake    = false
		this.isDisplay  = false
		this.isCutscene = false
		this.isZoning   = false
		this.isLogin    = false
	end,
	-------------------------------------------------------------------

	-- ログイン(キャラクター選択後のゲーム開始)時に実行する処理
	Startup = function( this )
		if( this.isLogin == true ) then return end
		if( UI:CheckResolution( Settings ) == false ) then
			-- 位置がリセットされた
			Config.save( Settings )
		end

		this.levelTable = {}
		this.levelTableWorks = {}
		this.effectiveTargets = {}

		this.isLogin = true
		this:CheckZoning()

		this:Display()
	end,

	-- ゾーン内にいるか確認する
	CheckZoning = function( this )
		local info = windower.ffxi.get_info()
		if( ( info.zone ~= nil and info.zone >= 0 ) or info.mog_house == true ) then
			this.isZoning = true
		end
		return this.isZoning
	end,

	-- 表示可能状態になっているか確認する
	Display = function( this )
		if( this.isDisplay == true ) then return true end
		if( this.isLogin == true and this.isZoning == true and this.isCutscene == false and UI:IsLoaded() == true ) then
			-- UIの準備が整っていたら最初の表示を行う
			this.isDisplay = true
			return true
		end
		return false
	end,
	-----------------------------------------------------------

	-- プレイヤーがエネミーのターゲットになっているか判定する
	CheckClaim = function( this, claimId, playerId )
		if claimId == playerId then
			return true
		else
			for i = 1, 5, 1 do
				member = windower.ffxi.get_mob_by_target( 'p' .. i )
				if member == nil then
					-- do nothing
				elseif claimId == member.id then
					return true
				end
			end
		end
		return false
	end,

	-- メンバー名を記録しておく(デバッグ用)
	memberNames = {},
	GetTargetName = function( this, targetId )
		if( this.memberNames == nil ) then
			this.memberNames = {}
		end

		local targetName = this.memberNames[ targetId ]

		if( targetName == nil ) then
			targetName = windower.ffxi.get_mob_name( targetId )

			if( targetName == nil ) then
				return '???(' .. targetId .. ')'
			end
		end

		return '[' .. targetName .. ']'
	end,

	-- ターゲットの色種別を取得する
	GetTargetColor = function( this, target )
		local color
		local player = windower.ffxi.get_mob_by_target( 'me' )

--		print( "tt = " .. target.spawn_type )

		-- 色の設定
		if( target.spawn_type == 1 or target.spawn_type == 13 or target.spawn_type == 14 ) then
			--  1 = 他のプレイヤー
			-- 13 = 自分
			-- 14 = フェイス
			if( target.in_party == false or ( target.in_party == true and target.id == player.id ) ) then
				-- 自分・その他(白)
				color = 1

				if( target.id == player.id ) then
					-- デバッグ用
					this.memberNames[ target.id ] = target.name
				end
			else
				-- パーティメンバー(水)
				color = 2

				-- デバッグ用
				this.memberNames[ target.id ] = target.name
			end
		elseif( target.spawn_type == 16 ) then
			--モンスター
			if( target.claim_id == 0 ) then
				-- 戦闘中ではない(黄)
				color = 3
			elseif( this:CheckClaim( target.claim_id, player.id ) == true ) then
				-- プレイヤーと戦闘中(赤)
				color = 4
			else
				-- 他のプレイヤーと戦闘中(紫)
				color = 5
			end
		elseif( target.spawn_type ==  2 ) then
			--ＮＰＣ(緑)
			color = 6
		elseif( target.spawn_type == 34 ) then
			-- オブジェクト(緑)
			color = 7
		else
			-- 不明
			color = 7
		end
		return color
	end,

	-- ゲージを強制消去する
	Hide = function( this )
		this.visible = false

		if( this.mtVisible == true ) then
			UI:HideMT()	-- メインターゲットゲージを消す
			this.mtVisible  = false
		end

		if( this.stVisible == true ) then
			UI:HideST()	-- サブターゲットゲージを消す
			this.stVisible  = false
		end

		this.mTarget = nil
		this.sTarget = nil
	end,


	-- 広域スキャンを実行する
	Scan = function( this )
		local info = windower.ffxi.get_info()
		if( this.isZoning == false or ( info ~= nil and info.mog_house == true ) or this.isCutscene == true or this.scanningUpdateTime ~= 0 ) then
			--条件的にスキャン不可
			return
		end

		-- 現在位置を取得する
		local isPlayerPosition = false
		local playerPosition = { X = 0, Y = 0 }

		local p = windower.ffxi.get_player()
		if( p ~= nil ) then
			local me = windower.ffxi.get_mob_by_id( p.id )
			if( me ~= nil ) then
				-- 現在位置が取得できた
				isPlayerPosition = true
				playerPosition.X = string.format( "%6.2f", me.x )
				playerPosition.Y = string.format( "%6.2f", me.y )
			end
		end	

		-- 現在位置が取得できないうちはまだスキャンを実行しない
		if( isPlayerPosition == false ) then
			return
		end

		-------------------------------

		-- スキャンを行う必要があるか判定する
		local useScanning = false
		if( this.lastScanningTime == 0 ) then

			if( this.isPlayerPosition == false ) then
				-- 現在位置が取れていないので設定して終了する
				this.isPlayerPosition = true
				this.playerPosition.X = playerPosition.X
				this.playerPosition.Y = playerPosition.Y
				return
			end

			-- 現在位置と前回のスキャン時の位置を比較して移動を行っていないならスキャンはしない
			local dx = playerPosition.X - this.playerPosition.X
			local dy = playerPosition.Y - this.playerPosition.Y
			local distance = math.sqrt( dx * dx + dy * dy )
			if( distance == 0 and this.finishInventoy == false ) then
				return 
			end

			useScanning = true	-- ゾーンチェンジ後などなので即時実行する
		else
			-- 一定時間経過か距離を移動していれば実行する
			if( ( os.clock() - this.lastScanningTime ) >= 60 ) then
				-- １分経過で再スキャンを実行する
				useScanning = true
			else
				if( this.isPlayerPosition == false ) then
					-- 現在位置が取れていないので設定して終了する
					this.isPlayerPosition = true
					this.playerPosition.X = playerPosition.X
					this.playerPosition.Y = playerPosition.Y
					return
				else
					-- 現在位置と前回のスキャン時の位置を比較して一定距離が離れていたらスキャンを実行する
					local dx = playerPosition.X - this.playerPosition.X
					local dy = playerPosition.Y - this.playerPosition.Y
					local distance = math.sqrt( dx * dx + dy * dy )
					if( distance >= 150 ) then
						-- 150m 以上離れたら再スキャンを実行する
						useScanning = true
					end
				end
			end
		end

		if( useScanning == false ) then
			-- スキャン不要
			return
		end

		-------------------------------

		local time = os.clock()

		-- 現在の時間を追加する
		this.lastScanningTime = time

		-- 現在位置を更新する
		this.isPlayerPosition = true
		this.playerPosition.X = playerPosition.X
		this.playerPosition.Y = playerPosition.Y

		-- スキャンを実行する
		local packet = Packets.new( 'outgoing', WIDE_SCAN,
		{
			[ 'Flags' ]		= 1,
			[ '_unknown1' ]	= 0,
			[ '_unknown2' ]	= 0,
		} )
		Packets.inject( packet )

		-- スキャン実行中表示のための情報を設定する
		this.scanningUpdateTime = time
		this.scanningActiveTime = time

		UI:ShowScanning( 0 )
	end,

	-------------------------------------------------------------------

	-- 全てのバフ効果管理対象を追加する
	AddEffectToTargets = function( this, data )

		local playerId = windower.ffxi.get_player().id

		local actor = windower.packets.parse_action( data )

		local ac = 0
		local ms =''
		local hae = 0
		local hse = 0

		if( #actor.targets >= 1 ) then
			-- ターゲットが１体以上存在する
			for _, target in pairs( actor.targets ) do
				ac = ac + #target.actions
				for i = 1, #target.actions do
					ms = ms .. tostring( target.actions[ i ].message ) .. ' '

					if( target.actions[ i ].has_add_effect ) then
						hae = hae + 1
					end
					if( target.actions[ i ].has_spike_effect ) then
						hse = hse + 1
					end
				end
			end
		end

--		PrintFF11( '[C]' .. actor.category .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' ap ' .. actor.param .. ' tc ' .. #actor.targets .. ' ac ' .. ac .. ' ms '.. ms .. ' hae ' .. hae .. ' hse ' .. hse )

		if( T{  2,  10, 12, 13, 14, 15 }:contains( actor.category ) == true ) then
			PrintFF11( "[Unknown Category]" .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' c ' .. actor.category .. ' p ' .. actor.param .. ' tc ' .. #actor.targets )
		end


		if( #actor.targets >= 1 ) then
			-- ターゲットが１体以上存在する
			for _, target in pairs( actor.targets ) do
				-- 処理するのはプレイヤー以外
				for i = 1, #target.actions do
					local message  = target.actions[ i ].message
					local effectId = target.actions[ i ].param 
					if( message == 33 ) then
						PrintFF11( "[COUNTER]" .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' .. this:GetTargetName( target.id ) .. ' c ' .. actor.category .. ' m ' .. message ' p ' .. actor.param .. ' e ' .. effectId .. ' ' .. i .. '/' .. #target.actions )
					end
				end

				if( #target.actions >  1 ) then
					for i = 1, #target.actions do
						local message  = target.actions[ i ].message
						local effectId = target.actions[ i ].param 
						if( T{   1,  15,  67,  70 }:contains( message ) == false ) then
							PrintFF11( "[Actions]" .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' .. this:GetTargetName( target.id ) .. ' c ' .. actor.category .. ' m ' .. message .. ' p ' .. actor.param .. ' e ' .. effectId .. ' ' .. i .. '/' .. #target.actions )
						end
					end
				end
			end
		end


		--[[
		if( #actor.targets >= 1 ) then
			-- ターゲットが１体以上存在する
			for _, target in pairs( actor.targets ) do
				for i = 1, #target.actions do
					local message = target.actions[ i ].message

					if( T{ 160, 164, 166 }:contains( message ) == true ) then
						-----------------------
						-- デバッグ用
						local effectId = target.actions[ i ].param

						local en = "???"
						if( Resources.buffs[ effectId ] ~= nil ) then
							en = Resources.buffs[ effectId ].name
						end

						PrintFF11( "Additional " .. ' ap ' .. actor.param .. ' → ' .. en .. '(' .. effectId .. ')' .. ' m ' .. message .. ' c ' .. actor.category .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' .. this:GetTargetName( target.id ) .. ' ac ' .. #target.actions )
					end
				end
			end
		end
		]]





		if( actor.actor_id ~= playerId ) then
			if( #actor.targets >= 1 ) then
				-- ターゲットが１体以上存在する
				for _, target in pairs( actor.targets ) do
					-- 処理するのはプレイヤー以外
					local message = target.actions[ 1 ].message
					if( message ==  29 or message ==  84 ) then
	--					PrintFF11( "a " .. this:GetTargetName( actor.actor_id ) .. ' c ' .. actor.category .. ' p ' .. actor.param .. ' m ' .. message .. ' t ' .. this:GetTargetName( target.id ) .. ' e ' .. effectId .. ' tc ' ..  #actor.targets )
						-- 行動者が麻痺している
						local targetId = actor.actor_id
						if( this.effectiveTargets[ targetId ] == nil ) then
							this.effectiveTargets[ targetId ] = {}
						end
						if( this.effectiveTargets[ targetId ][   4 ] == nil ) then
							-- 麻痺状態にする(ひとまず60秒)
							PrintFF11( this:GetTargetName( targetId ) .. "を麻痺状態にする" )
							this.effectiveTargets[ targetId ][   4 ] = { EndTime = os.clock() + 60, FromPlayer = false }
						end
					end
				end
			end
		end



		-- 無効
		--  7.ウェポンスキル(エネミースキル)準備
		--  8.魔法準備
		--  9.アイテム準備

		-- 有効
		--  1.オートアタック
		--  2.遠距離攻撃実行？
		--  3.ウェポンスキル(エネミースキル)発動
		--  4.魔法発動
		--  5.アイテム発動
		--  6.ジョブアビリティ発動
		-- 11.ウェポンスキル(エネミースキル)発動



		-- オートアタック
		if( actor.category == 1 ) then
			-- 通常攻撃

			-- message
			--  1 = ヒット effectId はダメージ値
			-- 15 = ミス   effectId は 0
			-- 31 = 身代わりとなって消えた effectId は 1

			-- 攻撃を受けたらブリンクは消去
			if( #actor.targets >= 1 ) then
				for _, target in pairs( actor.targets ) do
--					if( target.id ~= playerId ) then
						for i = 1, #target.actions do
							-- 対象がプレイヤー以外の場合のみ処理する
							local message  = target.actions[ i ].message
							local effectId = target.actions[ i ].param

							if( T{   1,  67 }:contains( message ) == true ) then
								--   1 通常攻撃
								--  67 クリティカルヒット
								-- 攻撃がヒットしたのでt回数制限のある絶対回避エフェクトを消す
								if( this.effectiveTargets[ target.id ] ~= nil ) then
									-- 既にバフ効果管理対象として登録されているターゲット
									this.effectiveTargets[ target.id ][  36 ] = nil	-- ブリンク
									this.effectiveTargets[ target.id ][  66 ] = nil	-- 分身1
									this.effectiveTargets[ target.id ][ 444 ] = nil	-- 分身2
									this.effectiveTargets[ target.id ][ 445 ] = nil	-- 分身3
									this.effectiveTargets[ target.id ][ 446 ] = nil	-- 分身4
								end
							elseif( message == 30 ) then
								--  30 対象が心眼による見切り発動
								if( this.effectiveTargets[ target.id ] ~= nil ) then
		--							PrintFF11( "見切り発動" )
									this.effectiveTargets[ target.id ][  67 ] = nil	-- 心眼
								end
							elseif( T{  15,  31,  70 }:contains( message ) == true ) then
								-- 無視して良いメッセージ
								--   0 攻撃(失敗する)→カウンターが発動
								--  15 ミス
								--  31 分身が身代わりになって消えた
								--  70 武器で攻撃をかわした。
							else
								-- その他
								PrintFF11( "[UM] c[" .. actor.category .. ']  m ' .. message .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' ..  this:GetTargetName( target.id ) .. ' e ' .. effectId .. ' ' .. tostring( i ) .. '/' .. #target.actions )
							end

							-- 追加効果
							if( target.actions[ i ].has_add_effect ) then
								-- 追加効果あり
								message  = target.actions[ i ].add_effect_message
								effectId = target.actions[ i ].add_effect_param

								if( T{ 160 }:contains( message ) == true ) then
									-- <有効>
									if( this.effectiveTargets[ target.id ] == nil ) then
										this.effectiveTargets[ target.id ] = {}
									end
									local duration = 60
									if( effectId ==  30 ) then
										-- 呪詛
										duration = 3600
									end
									this.effectiveTargets[ target.id ][ effectId ] = { EndTime = os.clock() + duration, FromPlayer = false }
								elseif( T{ 229 }:contains( message ) == true ) then
									-- <無効>
									-- 229 ダメージ
								else
									-- その他
									local en = "???"
									if( Resources.buffs[ effectId ] ~= nil ) then
										en = Resources.buffs[ effectId ].name
									end
									PrintFF11( "[HAE] c[" .. actor.category .. ']  m ' .. message .. ' e ' .. en .. '(' .. effectId .. ')' .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' ..  this:GetTargetName( target.id ) .. ' ' .. tostring( i ) .. '/' .. #target.actions )
								end
							end

							-- 反撃効果
							if( target.actions[ i ].has_spike_effect ) then
								-- 追加効果あり
								message  = target.actions[ i ].spike_effect_message
								effectId = target.actions[ i ].spike_effect_param

								if( T{ 0 }:contains( message ) == true ) then
									-- <有効>
								elseif( T{   33,  44 }:contains( message ) == true ) then
									-- <無効>
									--  33 カウンター
									--  44 スパイクダメージ
								else
									-- その他
									local en = "???"
									if( Resources.buffs[ effectId ] ~= nil ) then
										en = Resources.buffs[ effectId ].name
									end
									PrintFF11( "[HSE] c[" .. actor.category .. ']  m ' .. message .. ' e ' .. en .. '(' .. effectId .. ')' .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' ..  this:GetTargetName( target.id ) .. ' ' .. tostring( i ) .. '/' .. #target.actions )
								end
							end

						end
--					end
				end
			end
		end

		-- 魔法
		if( actor.category == 4 ) then

			-- スキル識別子をわかりやすく変数に格納する
			local spellId = actor.param

			------------------------------------

			if( spellId ~= nil ) then
				-- 有効な spellId
				local fromPlayer = ( actor.actor_id == playerId )

				-- 行動者にも効果があるか確認する
				if( fromPlayer == false ) then
					if( Spells[ spellId ] ~= nil and #Spells[ spellId ] >  0 and type( Spells[ spellId ][ 1 ] ) == 'table' ) then 
						if( type( Spells[ spellId ][ 1 ][ 1 ] ) == 'table' ) then
							-- 効果は対象と行動にN種類
							for i = 1, #Spells[ spellId ][ 2 ] do
								this:AddOneSpellEffectToTarget( spellId, actor.actor_id, false, Spells[ spellId ][ 2 ][ i ][ 1 ], Spells[ spellId ][ 2 ][ i ][ 2 ] )
							end
						end
					end
				end

				if( #actor.targets >= 1 ) then
					-- ターゲットが１体以上存在する
					for _, target in pairs( actor.targets ) do
--						if( target.id ~= playerId ) then	-- プレイヤーは別途より正確に処理するので処理は必要無し
							-- 処理するのはプレイヤー以外
							for i = 1, #target.actions do
								local message  = target.actions[ i ].message
								local effectId = target.actions[ i ].param

								-----------------------
								-- デバッグ用

								local en = "???"
								if( Resources.buffs[ effectId ] ~= nil ) then
									en = Resources.buffs[ effectId ].name
								end
								local sn = "???"
								if( Resources.spells[ spellId ] ~= nil ) then
									sn = Resources.spells[ spellId ].name
								end

								if( spellId >=    1 and spellId <= 1019 and Spells[ spellId ] == nil ) then
									PrintFF11( 'c[4]' .. ' s ' .. sn .. '(' .. spellId .. ') ' .. '→' .. ' e ' .. en .. '(' .. effectId .. ') ' .. ' m ' .. message .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' .. this:GetTargetName( target.id ) .. ' ' .. i .. '/' .. #target.actions )
								end
								-----------------------
								
								if( T{   2, 230, 252, 266 }:contains( message ) == true ) then
									-- □□□は、○○○の効果。(2はディアバイオ・230は自身・266は他人)
									this:AddSpellEffectToTarget( spellId, target.id, fromPlayer )							
								elseif( T{ 236, 237, 268, 269, 270, 271, 272 }:contains( message ) == true ) then
									-- □□□は、○○○の状態になった。
									this:AddSpellEffectToTarget( spellId, target.id, fromPlayer )							
								elseif( T{ 329, 330, 331, 332, 333, 334, 335 }:contains( message ) == true ) then
									-- □□□の、○○○を吸収した。(STR～CHR)　　アブゾタック　アブゾアキュル　アブゾアトリ
									this:AddSpellEffectToTarget( spellId, target.id, fromPlayer )							
								elseif( T{  83, 341, 342, 343, 344 }:contains( message ) == true ) then
									-- □□□は、○○○の状態から回復した。
									if( effectId ~= 0 ) then
										-- effectId = 0 は失敗 message 84 は失敗
										if this.effectiveTargets[ target.id ] then
											-- 効果消失
	--										PrintFF11( "[R]" .. en .. ' (' .. effectId .. ') ' .. " s " .. sn .. '(' .. spellId .. ') m ' .. message .. ' t ' .. target.id .. ' fp ' .. tostring( fromPlayer ) )
											this.effectiveTargets[ target.id ][ effectId ] = nil
										end
									end
								elseif( S{  84 }[ message ] ) then
									--  84 麻痺している
									if( this.effectiveTargets[ target.id ] == nil ) then
										this.effectiveTargets[ target.id ] = {}
									end
									if( this.effectiveTargets[ target.id ][   4 ] == nil ) then
										-- 麻痺状態にする(ひとまず60秒)
	--									PrintFF11( this:GetTargetName( targetId ) .. "を麻痺状態にする" )
										this.effectiveTargets[ target.id ][   4 ] = { EndTime = os.clock() + 60, FromPlayer = false }
									end
								elseif( T{   0,  75,  85, 106 }:contains( message ) == true ) then
									-- 無視して良いメッセージ
									--  75 効果なし
									--  85 レジストした
									-- 106 ひるんでいる
								else
									PrintFF11( "[UM] c[" .. actor.category .. "] e " .. en .. '(' .. effectId .. ') ' .. " s " .. sn .. '(' .. spellId .. ') m ' .. message .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' ..  this:GetTargetName( target.id ) .. ' ' .. i .. '/' .. #target.actions )
								end
							end
--						end
					end
				end
			end
		end

		if( actor.category == 5 ) then
			-- アイテム効果発動
		end

		-- ジョブアビリティ
		if( actor.category == 6 ) then

			-- 識別子をわかりやすく変数に格納する
			local abilityId = actor.param

			------------------------------------

			if( abilityId ~= nil ) then
				-- 有効な abilityId
				local fromPlayer = ( actor.actor_id == playerId )

				-- 行動者にも効果があるか確認する
				if( fromPlayer == false ) then
					if( Abilities[ abilityId ] ~= nil and #Abilities[ abilityId ] >  0 and type( Abilities[ abilityId ][ 1 ] ) == 'table' ) then 
						if( type( Abilities[ abilityId ][ 1 ][ 1 ] ) == 'table' ) then
							-- 効果は対象と行動にN種類
							for i = 1, #Abilities[ abilityId ][ 2 ] do
								this:AddOneAbilityEffectToTarget( abilityId, actor.actor_id, false, Abilities[ abilityId ][ 2 ][ i ][ 1 ], Abilities[ abilityId ][ 2 ][ i ][ 2 ] )
							end
						end
					end
				end

				if( #actor.targets >= 1 ) then
					-- ターゲットが１体以上存在する
					for _, target in pairs( actor.targets ) do
--						if( target.id ~= playerId ) then	-- プレイヤーは別途より正確に処理するので処理は必要無し
							-- 処理するのはプレイヤー以外
							for i = 1, #target.actions do
								local message  = target.actions[ i ].message
								local effectId = target.actions[ i ].param

								-----------------------
								-- デバッグ用

								local en = "???"
								if( Resources.buffs[ effectId ] ~= nil ) then
									en = Resources.buffs[ effectId ].name
								end
								local sn = "???"
								if( Resources.job_abilities[ abilityId ] ~= nil ) then
									sn = Resources.job_abilities[ abilityId ].name
								end

								if( abilityId >=    1 and abilityId <=  970 and Abilities[ abilityId ] == nil ) then
									PrintFF11( 'c[6]' .. ' s ' .. sn .. '(' .. abilityId .. ') ' .. '→' .. ' e ' .. en .. '(' .. effectId .. ') ' .. ' m ' .. message .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' .. this:GetTargetName( target.id ) .. ' ' .. i .. '/' .. #target.actions )
								end
								-----------------------
								
								if( T{ 100, 115, 116, 117, 118, 119, 120, 121, 126, 131, 134, 285, 286, 287, 304, 319 }:contains( message ) == true ) then
									-- 100 アビリティ！
									-- 120 命中率アップ
									-- 121 回避率アップ
									-- 126 とんずら
									-- 131 不死生物に対する種族防御を得た！
									this:AddAbilityEffectToTarget( abilityId, target.id, fromPlayer )							
								elseif( T{ 0 }:contains( message ) == true ) then
									-- 無視して良いメッセージ
								else
									PrintFF11( '[UM] c[' .. actor.category .. ']' .. ' s ' .. sn .. '(' .. abilityId .. ')' .. ' e ' .. en .. '(' .. effectId .. ')' .. ' m ' .. message .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' ..  this:GetTargetName( target.id ) .. ' ' .. i .. '/' .. #target.actions )
								end
							end
--						end
					end
				end
			end
		end

		-- スキル
		if( actor.category ==  3 or actor.category == 11 ) then

			-- 識別子をわかりやすく変数に格納する
			local skillId = actor.param

			------------------------------------

			if( skillId ~= nil ) then
				-- 有効な SkillId
				local fromPlayer = ( actor.actor_id == playerId )

				-- 行動者にも効果があるか確認する
				if( fromPlayer == false ) then
					if( Skills[ skillId ] ~= nil and #Skills[ skillId ] >  0 and type( Skills[ skillId ][ 1 ] ) == 'table' ) then 
						if( type( Skills[ skillId ][ 1 ][ 1 ] ) == 'table' ) then
							-- 効果は対象と行動にN種類
							for i = 1, #Skills[ skillId ][ 2 ] do
								this:AddOneSkillEffectToTarget( skillId, actor.actor_id, false, Skills[ skillId ][ 2 ][ i ][ 1 ], Skills[ skillId ][ 2 ][ i ][ 2 ] )
							end
						end
					end
				end

				if( #actor.targets >= 1 ) then
					-- ターゲットが１体以上存在する
					for _, target in pairs( actor.targets ) do
	--					if( target.id ~= playerId ) then	-- プレイヤーは別途より正確に処理するので処理は必要無し
							-- 処理するのはプレイヤー以外
							for i = 1, #target.actions do
								local message  = target.actions[ i ].message
								local effectId = target.actions[ i ].param

								local skillType = 1	-- WeaponSkill
								if( T{ 110 }:contains( message ) == true ) then
									-- Ability を使用する
									skillType = 0
								end

								-----------------------
								-- デバッグ用

								local en = "???"
								if( Resources.buffs[ effectId ] ~= nil ) then
									en = Resources.buffs[ effectId ].name
								end
								local sn = "???"
								local max = 0

								if( skillType == 0 ) then
									-- Ability
									if( Resources.job_abilities[ skillId ] ~= nil ) then
										sn = Resources.job_abilities[ skillId ].name
									end
									max =  970
								else
									-- WeaponSkill
									if( skillId <  256 ) then
										if( Resources.weapon_skills[ skillId ] ~= nil ) then
											sn = Resources.weapon_skills[ skillId ].name
										end
									else
										if( Resources.monster_abilities[ skillId ] ~= nil ) then
											sn = Resources.monster_abilities[ skillId ].name
										end
									end
									max = 4261
								end

--								if( skillId >=    1 and skillId <= max and Skills[ skillId ] == nil ) then
									PrintFF11( 'c[' .. actor.category .. ']' .. ' s ' .. sn .. '(' .. skillId .. ')' .. ' e ' .. en .. '(' .. effectId .. ')' .. ' m ' .. message .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' .. this:GetTargetName( target.id ) .. ' ' .. i .. '/' .. #target.actions )
--								end

								-----------------------
								
								-- 185 は PC 264 は　NPC
								-- 状態異常 242 277
								if( T{   1, 110, 185, 187, 194, 224, 242, 243, 264, 277 }:contains( message ) == true ) then

									if( skillType == 0 ) then
										-- Ability
										this:AddAbilityEffectToTarget( skillId, target.id, fromPlayer )
									else
										-- WeaponSkill
										this:AddSkillEffectToTarget( skillId, target.id, fromPlayer )
									end
									--   1 : Actor は Target に Effect のダメージ。
									-- 110 : (Ability) Actor は Skill を実行。Target は Effect のダメージ
									-- 185 : Actor は Skill を実行。Target は Effect のダメージ。
									-- 187 : Actor は Skill を実行。Target から Effect の HP吸収。
									-- 194 : Actor は Skill を実行。Target は Effect の状態になった。
									-- 224 : Actor は Skill を実行。Target は Effect のMP回復。
									-- 242 : Actor は Skill を実行。Target は Effect の状態になった。
									-- 264 : Target は Effect のダメージ。
									-- 277 : Target は Effect の状態になった。 
								elseif( T{ 188, 189, 282, 283 }:contains( message ) == true ) then
									-- 無視して良いメッセージ
									-- 188 ミス
									-- 189 効果なし
									-- 282 ミス
									-- 283 効果なし
								else
									PrintFF11( '[UM] c[' .. actor.category .. ']' .. ' s ' .. sn .. '(' .. skillId .. ')' .. ' e ' .. en .. '(' .. effectId .. ')' .. ' m ' .. message .. ' a ' .. this:GetTargetName( actor.actor_id ) .. ' t ' ..  this:GetTargetName( target.id ) .. ' ' .. i .. '/' .. #target.actions )
								end
							end
	--					end
					end
				end
			end
		end

		-- 行動出来ているなら消去しても良い効果を処理する
		if( actor.actor_id ~= playerId ) then
			-------------  全ての行動において、そのactor(行動した側)の弱体を消す処理
			--  弱体が入ったかどうかログに出ない場合（物理青魔やWS）のための処理
			if( this.effectiveTargets[ actor.actor_id ] ~= nil ) then
				-- 既にバフ効果管理対象として登録されているターゲット
				this.effectiveTargets[ actor.actor_id ][ 10 ] = nil	-- スタン効果クリア
				this.effectiveTargets[ actor.actor_id ][  2 ] = nil	-- 睡眠効果クリア
			end
		end
	end,

	-- 魔法による効果を追加する
	AddSpellEffectToTarget = function( this, spellId, targetId, fromPlayer )

		if( Spells[ spellId ] == nil ) then

			local sn = "???"
			if( Resources.spells[ spellId ] ~= nil ) then
				sn = Resources.spells[ spellId ].name
			end

			PrintFF11( "[Spell Error] " .. sn .. '(' .. spellId .. ')' .. ' to ' .. this:GetTargetName( targetId ) )
			return
		end
		if( #Spells[ spellId ] == 0 ) then
			-- 処理が不要
			return
		end

		if( this.effectiveTargets[ targetId ] == nil ) then
			-- 対象のデバフ情報初期化
			this.effectiveTargets[ targetId ] = {}
		end

		if( T{  23,  24,  25,  26,  27,  33,  34,  35,  36,  37, 230, 231, 232, 233, 234 }:contains( spellId ) == true ) then
			-- ディア系・バイオ系
			local priorities = {
				[  23 ] =  1, -- ディア
				[  24 ] =  3, -- ディアⅡ
				[  25 ] =  5, -- ディアⅢ
				[  26 ] =  7, -- ディアⅣ
				[  27 ] =  9, -- ディアⅤ

				[  33 ] =  1, -- ディアガ
				[  34 ] =  3, -- ディアガⅡ
				[  35 ] =  5, -- ディアガⅢ
				[  36 ] =  7, -- ディアガⅣ
				[  37 ] =  9, -- ディアガⅤ

				[ 230 ] =  2, -- バイオ
				[ 231 ] =  4, -- バイオⅡ
				[ 232 ] =  6, -- バイオⅢ
				[ 233 ] =  8, -- バイオⅣ
				[ 234 ] = 10, -- バイオⅤ
			}

			-- ディア系とバイオ系(上書きに失敗したかはわからないため独自に処理する必要がある)

			-- 優先順位を取得する
			local activePriority = 0
			local activeEffect = this.effectiveTargets[ targetId ][ 134 ] or this.effectiveTargets[ targetId ][ 135 ]
			if( activeEffect ~= nil ) then
				activePriority = priorities[ activeEffect.SpellId ]
			end
		
			if( priorities[ spellId ] >  activePriority ) then
				-- 新しくかけるスキルの方が優先順位が高い場合は新しいスキルで情報を上書きする
				if( T{  23,  24,  25,  26,  27,  33,  34,  35,  36,  37 }:contains( spellId ) == true ) then
					-- ディア系
					this.effectiveTargets[ targetId ][ 134 ] = { EndTime = os.clock() + Spells[ spellId ][ 2 ], SpellId = spellId, FromPlayer = fromplayer }
					this.effectiveTargets[ targetId ][ 135 ] = nil
				elseif( T{ 230, 231, 232, 233, 234 }:contains( spellId ) == true ) then
					-- バイオ系
					this.effectiveTargets[ targetId ][ 134 ] = nil
					this.effectiveTargets[ targetId ][ 135 ] = { EndTime = os.clock() + Spells[ spellId ][ 2 ], SpellId = spellId, FromPlayer = fromPlayer }
				end
			end
	
		elseif( T{ 278, 279, 280, 281, 282, 283, 284, 285, 885, 886, 887, 888, 889, 890, 891, 892 }:contains( spellId ) == true ) then
			-- 計略系
			this.effectiveTargets[ targetId ][ 186 ] = { EndTime = os.clock() + Spells[ spellId ][ 2 ], SpellId = spellId, fromPlayer = fromPlayer }
		else
			-- その他
			if( type( Spells[ spellId ][ 1 ] ) ~= 'table' ) then 
				-- 効果は対象に1種類
				this:AddOneSpellEffectToTarget( spellId, targetId, fromPlayer, Spells[ spellId ][ 1 ], Spells[ spellId ][ 2 ] )
			else
				if( type( Spells[ spellId ][ 1 ][ 1 ] ) ~= 'table' ) then
					-- 効果は対象にN種類
					for i = 1, #Spells[ spellId ] do
						this:AddOneSpellEffectToTarget( spellId, targetId, fromPlayer, Spells[ spellId ][ i ][ 1 ], Spells[ spellId ][ i ][ 2 ] )
					end
				else
					-- 効果は対象と行動にN種類
					for i = 1, #Spells[ spellId ][ 1 ] do
						this:AddOneSpellEffectToTarget( spellId, targetId, fromPlayer, Spells[ spellId ][ 1 ][ i ][ 1 ], Spells[ spellId ][ 1 ][ i ][ 2 ] )
					end
				end
			end
		end
	end,

	-- 1種類の効果のみを設定する
	AddOneSpellEffectToTarget = function( this, spellId, targetId, fromPlayer, effectId, duration )

		if( effectId ~= 0 ) then
			this.effectiveTargets[ targetId ][ effectId ] = { EndTime = os.clock() + duration, SpellId = spellId, FromPlayer = fromPlayer }
			this:ChoiseEffect( targetId, effectId )
		end
	end,

	-- アビリティによる効果を追加する
	AddAbilityEffectToTarget = function( this, abilityId, targetId, fromPlayer )

		if( Abilities[ abilityId ] == nil ) then

			local sn = "???"
			if( Resources.job_abilities[ abilityId ] ~= nil ) then
				sn = Resources.job_abilities[ abilityId ].name
			end

			PrintFF11( "[Ability Error] " .. sn .. '(' .. abilityId .. ')' .. ' to ' .. this:GetTargetName( targetId ) )
			return
		end
		if( #Abilities[ abilityId ] == 0 ) then
			-- 処理が不要
			return
		end

		if( this.effectiveTargets[ targetId ] == nil ) then
			-- 対象のデバフ情報初期化
			this.effectiveTargets[ targetId ] = {}
		end

		if( T{   1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,  12,  13,  14,  15 }:contains( spellId ) == true ) then
			-- 使用されていないアビリティ番号
		else
			-- その他
			if( type( Abilities[ abilityId ][ 1 ] ) ~= 'table' ) then 
				-- 効果は対象に1種類
				this:AddOneAbilityEffectToTarget( abilityId, targetId, fromPlayer, Abilities[ abilityId ][ 1 ], Abilities[ abilityId ][ 2 ] )
			else
				if( type( Abilities[ abilityId ][ 1 ][ 1 ] ) ~= 'table' ) then
					-- 効果は対象にN種類
					for i = 1, #Abilities[ abilityId ] do
						this:AddOneAbilityEffectToTarget( abilityId, targetId, fromPlayer, Abilities[ abilityId ][ i ][ 1 ], Abilities[ abilityId ][ i ][ 2 ] )
					end
				else
					-- 効果は対象と行動にN種類
					for i = 1, #Abilities[ abilityId ][ 1 ] do
						this:AddOneAbilityEffectToTarget( abilityId, targetId, fromPlayer, Abilities[ abilityId ][ 1 ][ i ][ 1 ], Abilities[ abilityId ][ 1 ][ i ][ 2 ] )
					end
				end
			end
		end
	end,

	-- 1種類の効果のみを設定する
	AddOneAbilityEffectToTarget = function( this, abilityId, targetId, fromPlayer, effectId, duration )

		this.effectiveTargets[ targetId ][ effectId ] = { EndTime = os.clock() + duration, AbilityId = abilityId, FromPlayer = fromPlayer }
		this:ChoiseEffect( targetId, effectId )
	end,


	-- スキルによる効果を追加する
	AddSkillEffectToTarget = function( this, skillId, targetId, fromPlayer )

		if( Skills[ skillId ] == nil ) then

			local sn = '???'
			if( skillId <  256 ) then
				if( Resources.weapon_skills[ skillId ] ~= nil ) then
					sn = Resources.weapon_skills[ skillId ].name
				end
			else
				if( Resources.monster_abilities[ skillId ] ~= nil ) then
					sn = Resources.monster_abilities[ skillId ].name
				end
			end

			PrintFF11( "[Skill Error] " .. sn .. '(' .. skillId .. ')' .. ' to ' .. this:GetTargetName( targetId ) )
			return
		end
		if( #Skills[ skillId ] == 0 ) then
			-- 処理が不要
			return
		end

		if( this.effectiveTargets[ targetId ] == nil ) then
			-- 対象のデバフ情報初期化
			this.effectiveTargets[ targetId ] = {}
		end

		if( T{ 3494 }:contains( skillId ) == true ) then
			-- ウォークザープランクの強化効果の全消去
			for i = 1, #Settings.EffectEnabled do
				local effectId = Settings.EffectEnabled[ i ]
				if( effectId <  0 ) then
					break	-- 終了
				end
				this.effectiveTargets[ targetId ][ effectId ] = nil
			end
		end

		if( T{ 256 }:contains( skillId ) == true ) then
			-- 使用されていないアビリティ番号
		else
			-- その他
			if( type( Skills[ skillId ][ 1 ] ) ~= 'table' ) then 
				-- 効果は対象に1種類
				this:AddOneSkillEffectToTarget( skillId, targetId, fromPlayer, Skills[ skillId ][ 1 ], Skills[ skillId ][ 2 ] )
			else
				if( type( Skills[ skillId ][ 1 ][ 1 ] ) ~= 'table' ) then
					-- 効果は対象にN種類
					for i = 1, #Skills[ skillId ] do
						this:AddOneSkillEffectToTarget( skillId, targetId, fromPlayer, Skills[ skillId ][ i ][ 1 ], Skills[ skillId ][ i ][ 2 ] )
					end
				else
					-- 効果は対象と行動にN種類
					for i = 1, #Skills[ skillId ][ 1 ] do
						this:AddOneSkillEffectToTarget( skillId, targetId, fromPlayer, Skills[ skillId ][ 1 ][ i ][ 1 ], Skills[ skillId ][ 1 ][ i ][ 2 ] )
					end
				end
			end
		end
	end,

	-- 1種類の効果のみを設定する
	AddOneSkillEffectToTarget = function( this, skillId, targetId, fromPlayer, effectId, duration )

		if( skillId ~= 0 and duration ~= nil ) then
			this.effectiveTargets[ targetId ][ effectId ] = { EndTime = os.clock() + duration, SkillId = skillId, FromPlayer = fromPlayer }
			this:ChoiseEffect( targetId, effectId )

			if( skillId == 484 ) then
				-- ブラッククラウドは空蝉も全消去
				this.effectiveTargets[ targetId ][  66 ] = nil	-- 分身
			end
		end
	end,
	
	
	-- 複数同時に付着しない効果の選別
	ChoiseEffect = function( this, targetId, effectId )
		-- いずれか１つのみ有効な効果の処理

		-- ためる・ウォークライはいずれか１つだけ有効
		local speed_effectIds = T{  45,  68, 615 }
		if( speed_effectIds:contains( effectId ) == true ) then
			for i = 1, #speed_effectIds do
				if( speed_effectIds[ i ] ~= effectId ) then
					this.effectiveTargets[ targetId ][ speed_effectIds[ i ] ] = nil
				end
			end
		end

		-- スロウ・ヘイスト・スナップはいずれか１つだけ有効
		local speed_effectIds = T{  13,  33, 565, 580, 581 }
		if( speed_effectIds:contains( effectId ) == true ) then
			for i = 1, #speed_effectIds do
				if( speed_effectIds[ i ] ~= effectId ) then
					this.effectiveTargets[ targetId ][ speed_effectIds[ i ] ] = nil
				end
			end
		end

		-- バ系はいずれか１つだけ有効
		local ba_effectIds = T{ 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 286 }
		if( ba_effectIds:contains( effectId ) == true ) then
			for i = 1, #ba_effectIds do
				if( ba_effectIds[ i ] ~= effectId ) then
					this.effectiveTargets[ targetId ][ ba_effectIds[ i ] ] = nil
				end
			end
		end

		-- エン系はいずれか１つだけ有効
		local en_effectIds = T{  94,  95,  96,  97,  98,  99, 274, 277, 278, 279, 280, 281, 282, 288, 487, 488 }
		if( en_effectIds:contains( effectId ) == true ) then
			for i = 1, #en_effectIds do
				if( en_effectIds[ i ] ~= effectId ) then
					this.effectiveTargets[ targetId ][ en_effectIds[ i ] ] = nil
				end
			end
		end

		-- スパイク系はいずれか１つだけ有効
		local spike_effectIds = T{   34,  35,  38, 173, 573 }
		if( spike_effectIds:contains( effectId ) == true ) then
			for i = 1, #spike_effectIds do
				if( spike_effectIds[ i ] ~= effectId ) then
					this.effectiveTargets[ targetId ][ spike_effectIds[ i ] ] = nil
				end
			end
		end
	end,


	-- 対象もしくは効果を除去する(Action Message パケット受信で呼び出される)
	RemoveEffectFromTarget = function( this, data )
		local targetId  = data:unpack( 'I', 0x09 )
		local effectId  = data:unpack( 'I', 0x0D )
		local message   = data:unpack( 'H', 0x19 ) % 32768

		local playerId = windower.ffxi.get_player().id

		--[[
		if( effectId ~= 0 ) then
			local en = "???"
			if( Resources.buffs[ effectId ] ~= nil ) then
				en = Resources.buffs[ effectId ].name
			end
			PrintFF11( "release " .. en .. '(' .. effectId .. ')  m ' .. message .. " tId " .. targetId .. ' pId ' .. playerId )
		end
		]]

		-- プレイヤーの場合は別途処理するので無視する(後で有効化)
--		if( targetId ~= playerId ) then
--			return
--		end

		if S{   6,  20, 113, 406, 605, 646 }[ message ] then
			-- 対象消失
			if( targetId ~= playerId ) then
				this.effectiveTargets[ targetId ] = nil
			end
		elseif S{ 204, 206 }[ message ] then
			if( targetId ~= playerId ) then
				if this.effectiveTargets[ targetId ] then
					-- 効果消失
					this.effectiveTargets[ targetId ][ effectId ] = nil
				end
			end
		elseif( S{   4,   5,  16,  17,  36,  38,  45,  48,  53,  71,  78,  96, 219, 234, 313, 410, 512, 705 }[ message ] ) then
			-- 無視して良いメッセージ
			--   4 対象は範囲外
			--   5 対象が見えない
			--  16 詠唱が中断された
			--  17 魔法を唱えることができない
			--  36 対象を見失った
			--  38 スキル値上昇
			--  45 ウェポンスキル習得
			--  48 対象にその魔法はかけられない
			--  53 スキルレベルアップ
			--  71 実行できない
			--  78 対象は遠くにいる
			--  96 既に覚えている魔法です
			-- 219 姿が見えないため技を使えない
			-- 234 自動でターゲットを変更
			-- 313 遠くにいるため実行できない
			-- 410 効果対象がいないので、そのアイテムは使用できません。
			-- 512 両手武器を装備していないとグリップは装備できない
			-- 705 エミネンス・レコードを受領
		else
			local en = "???"
			if( Resources.buffs[ effectId ] ~= nil ) then
				en = Resources.buffs[ effectId ].name
			end
			PrintFF11( "Unknown Message to Remove m = " .. message .. ' t = ' .. this:GetTargetName( targetId ) .. ' ' .. en .. '(' .. effectId .. ')' )
		end
	end,

	-- 表示する効果情報を取得する
	GetEffects = function( this, targetId, playerId, limit )

		local effects = nil
		if( this.effectiveTargets[ targetId ] ~= nil ) then

			local category = 1	-- 最初は強化系

			effects = {}
			for i = 1, #Settings.EffectEnabled, 1 do
				local effectId = Settings.EffectEnabled[ i ]
				if( effectId >= 0 ) then
					if( this.effectiveTargets[ targetId ][ effectId ] ~= nil ) then

						if( targetId ~= playerId and this.effectiveTargets[ targetId ][ effectId ].FromPlayer == false ) then
							-- 対象がプレイヤーではなく且つその効果がプレイヤー起因ではない場合
							-- 効果の終了時間に達していたら効果を消去する
							if( this.effectiveTargets[ targetId ][ effectId ].EndTime ~= 0 and ( this.effectiveTargets[ targetId ][ effectId ].EndTime - os.clock() ) <= 0 ) then
								this.effectiveTargets[ targetId ][ effectId ]= nil
							end
						end
						
						-- 終了時間で効果が消えていない場合に改めて表示対象とする
						if( this.effectiveTargets[ targetId ][ effectId ] ~= nil ) then
							local c = #effects + 1
							-- 効果を登録
							effects[ c ] = {}
							effects[ c ].EffectId = effectId
							effects[ c ].EndTime  = this.effectiveTargets[ targetId ][ effectId ].EndTime
							effects[ c ].Category = category	-- 1=強化系・2=弱化系
							limit = limit - 1
						end
					end
				else
					-- カテゴリ切り替え
					category = 2	-- 弱化系
				end

				if( limit == 0 ) then break end
			end
			if( #effects == 0 ) then effects = nil end
		end

		return effects
	end,

	-- レベルを取得する(エネミーのみ有効)
	GetLevel = function( this, targetIndex )
		local level = '?'
		if( this.levelTable[ targetIndex ] ~=  nil ) then
			level = this.levelTable[ targetIndex ].Level
			if( lavel == 0 ) then
				level = '?'
				this.lastScanningTime = 0	-- レベルが不明なエネミーを発見したのでスキャンを試みる
			end
		else
			this.lastScanningTime = 0	-- レベルが不明なエネミーを発見したのでスキャンを試みる
		end
		return level
	end,
}
-----------------------------------------------------------------------

-- イベント登録とイベント実行
addon.RegisterEvents = function( this )

	-- アドオンがロードされた際のイベントを登録する(グローバル処理が実行された後に呼びされる)
	windower.register_event( 'load', function()
		this:Prepare()
		if( windower.ffxi.get_info().logged_in == true ) then
			-- ゲームが開始状態である場合のみ準備処理を呼ぶ(この準備準備は基本的にコマンドでロードされた場合のみ呼ばれる事になる)
			this:Startup()	-- スクリプトのリロードのケース
		end	
	end)

	-- アドオンがアンロードされた際のイベントを登録する(アドオンを明示的にアンロードした時にしか呼ばれない)
	windower.register_event( 'unload', function()
	end)

	-- ログインした際のイベントを登録する(キャラクターを選択してゲームが開始した後に呼ばれる)
	windower.register_event( 'login', function()
		-- キャラクター選択以前に処理する事は基本的に無いのでこのタイミングで準備処理を実行する事が正しい
		-- 付け加えるならばこのイベントの直前に再度設定情報が読み込まれるようなのでこれ以前のオンメモリの設定情報の変更は無意味である
		this:Startup()
	end)

	-- ログアウトした際のイベントを登録する(タイトル画面に戻る)スクリプト自体はまだ生きている
	windower.register_event( 'logout', function()
		this:Destroy()
	end)

	-- パケット受信時のイベントを登録する
	windower.register_event( 'incoming chunk', function( id, original, modified, isInjected, isBlocked )
		if( this:Display() == false ) then
			return	-- 準備が整っていない
		end
		-----------------------------------

		if( id == LOGIN_ZONE ) then
			-- ゾーンイン
			this.isZoning = true	-- ゾーン内
			this.levelTable = {}
			this.levelTableWorks = {}
			this.effectiveTargets = {}
			this.lastScanningTime = 0
			this.isPlayerPosition = false
			this.finishInventoy = false
		elseif( id == 0x1D ) then
			-- アイテム情報を全て取得した(ゾーンチェンジの完全完了判定)
			this.finishInventoy = true
		elseif( id == LOGOUT_ZONE ) then
			-- ゾーンアウト
			this:Hide()
			this.effectiveTargets = nil
			this.levelTableWorks = nil
			this.levelTable = nil
			this.isZoning = false	-- ゾーン外
		elseif( id == WIDE_SCAN ) then
			-- ワイドスキャン
			local packet = Packets.parse( 'incoming', original )
--			print( "I " .. packet.Index .. ' L ' .. packet.Level )
			this.levelTableWorks[ packet.Index ] = { Level = packet.Level }
			this.scanningUpdateTime = os.clock()	-- 表示継続
		elseif( id == ACTION ) then
			-- チャージが終了しスキルが発動した
			this:AddEffectToTargets( original )
		elseif( id == ACTION_MESSAGE ) then
			-- 効果が終了した
			this:RemoveEffectFromTarget( original )
		elseif( id == 0x63 ) then
			-- プレイヤーの効果情報を更新する
			if( original:byte( 5 ) == 9 ) then

				local p = windower.ffxi.get_player()
				if( p ~= nil ) then
					local playerId = p.id

					-- 完全にクリアする
					this.effectiveTargets[ playerId ] = {}

					local els = ''

					-- 最大３２個の効果
					for i = 1, 32 do

						-- 効果識別子
						local effectId = original:unpack( 'H', i * 2 + 7 )

						if  effectId ~= 0 and effectId ~= 255 then -- 255 is used for "no buff"
							if( Settings.EffectEnabled:contains( effectId ) == true ) then

								-- 終了時間を取得する
								local endTime
								if( effectId ~= 474 ) then
									endTime = original:unpack( 'I', i * 4 + 0x45 ) / 60 + 501079520 + 1009810800 + 71582788
									endTime = ( endTime - os.time() ) + os.clock()
								else
									-- 一時技能
									endTime = -1
								end
--								print( "eid:" .. effectId .. ' t:' .. endTime )

								local en = "???"
								if( Resources.buffs[ effectId ] ~= nil ) then
									en = Resources.buffs[ effectId ].name
								end

								els = els .. en .. '(' .. effectId .. ')'

								if( endTime >  0 ) then
									els = els .. '[' .. math.ceil( endTime - os.clock() ) ..']'
								end
								els = els .. ' '

								-- 有効な効果
								this.effectiveTargets[ playerId ][ effectId ] = { SkillId = 0, EndTime = endTime }	-- 原因となった技能は不明
							end
						end
					end

					if( #els >  0 ) then
						els = '[PS] ' .. els
						PrintFF11( els )
					end
				end
			end
		elseif( id == 0x76 ) then
			print( "Member Buffers" )
			for  k = 0, 4 do
				local memberId = original:unpack( 'I', k * 48 + 5 )
				if memberId ~= 0 then
					this.effectiveTargets[ memberId ] = {}

					for i = 1, 32 do
						local effectId = original:byte( k * 48 + 5 + 16 + i - 1 ) + 256 * ( math.floor( data:byte( k * 48 + 5 + 8+ math.floor( ( i - 1 ) / 4 ) ) / 4 ^ ( ( i - 1 ) % 4 )  ) % 4 )
						if( effectId ~= 0 ) then
							print( "MemberId " .. memberId .. " EffectId " .. effectId )
							-- パーティメンバーの場合は終了時間がわからない
							this.effectiveTargets[ memberId ][ effectId ] = { SkillId = 0, EndTime = 0 }	-- 原因となった技能は不明・終了時間も不明
						end
					end
				end
			end			
		end
	end)

	-- 状況変化の際に呼び出されるイベントを登録する(カットシーン対応)
	windower.register_event( 'status change', function( statusId )
		if( this:Display() == false ) then
			return	-- 準備が整っていない
		end
		-----------------------------------
		-- カットシーンかどうかで表示を切り替える
		if( statusId == CUTSCENE_STATUS_ID ) then
			-- カットシーンに入った
			this:Hide()
			this.isCutscene = true
		else
			-- カットシーンから出た
			this.isCutscene = false
		end
	end)

	-- ターゲットが変更された際に呼びたされるイベントを登録する
	windower.register_event( 'target change', function( index )
		if( this:Display() == false ) then
			return	-- 準備が整っていない
		end
		-----------------------------------
		if( index == 0 ) then
			-- 何もターゲットしていない
			this:Hide()
		else
			-- 何らかをターゲットした
			this.visible = true
		end
	end)

	-- ゾーンアウトした際に呼び出されるイベントを登録する
--	windower.register_event( 'zone change', function()
--		-- バフ効果管理情報をクリアする
--		this.effectiveTargets = {}
--	end)

	-----------------------------------------------------------------------

	-- 画面描画が行われる前に呼び出されるイベントを登録する
	windower.register_event( 'prerender',  function( ... )
		if( this:Display() == false ) then
			return	-- 準備が整っていない
		end
		-----------------------------------

		local mtVisible = false
		local stVisible = false

		local mTarget = nil
		local sTarget = nil

		local targetName
		local level
		local color
		local isSameTarget
		local effects

		local info = windower.ffxi.get_info()
		if this.visible == true and ( this.isZoning == true or info.mog_house == true ) and this.isCutscene == false then

			-- 表示可能な状態

			-- 注意:
			-- 　保持している前フレームのターゲットインスタンスは、
			-- 　表示と非表示の状態変化の判定には使えない。
			-- 　ターゲットインスタンスが無効になった瞬間に、
			-- 　保持している前フレームのターゲットインスタンスも nil になる。
			-- 　よって、表紙と非表示の状態変化の判定には、
			-- 　別途 bool 型の変数を用意する必要がある。

--			local player = windower.ffxi.get_mob_by_target( 'me' )
			local playerId = windower.ffxi.get_player().id


			mTarget = windower.ffxi.get_mob_by_target( 't' )
			sTarget = windower.ffxi.get_mob_by_target( 'st' )

			-- ターゲットが消失してサブターゲットが存在している場合はサブターゲットをターゲットとする
			if( sTarget ~= nil and mTarget == nil ) then
				mTarget = sTarget
				sTarget = nil
			end
			
			if( mTarget ~= nil and sTarget ~= nil and mTarget.id == sTarget.id ) then
				-- メインターゲットとサブターゲットが同じならサブターゲットの表示を消す
				sTarget = nil
			end

			if( mTarget ~= nil ) then
				-- 色の設定
				color = this:GetTargetColor( mTarget )

				-- ターゲットの変更判定
				isSameTarget = ( this.mTarget ~= nil and this.mTarget.id == mTarget.id )

				-- ターゲットにバフ効果情報が存在する場合はそれも渡す
				effects = this:GetEffects( mTarget.id, playerId, 12 )

				-- 対象の名前
				targetName = mTarget.name

				-- エネミーのレベルを取得する
				level = nil
				if( color >= 3 and color <= 5 ) then
					-- ノートリアスモンスターの場合は名前にランク文字列を付与する
					if( Nms[ targetName ] ~= nil ) then
						targetName = targetName .. ' ' .. Nms[ targetName ]
					end
					-- レベルを表示するのはエネミーのみ
					level = this:GetLevel( mTarget.index )
				end

				-- メインターゲットゲージの表示を設定する
				UI:ShowMT( targetName, level, mTarget.hpp, color, isSameTarget, effects )

				mtVisible = true

				-- バフ効果情報からターゲットを削除
				if( mTarget.hpp == 0 and this.effectiveTargets[ mTarget.id ] ~= nil ) then
					this.effectiveTargets[ mTarget.id ] = nil
				end

				---------------------------

				-- サブターゲット
				if( sTarget ~= nil ) then
					-- 色の設定
					color = this:GetTargetColor( sTarget )

					-- 前フレームと同じ対象かどうか
					isSameTarget = ( this.sTarget ~= nil and this.sTarget.id == sTarget.id )

					-- ターゲットにバフ効果情報が存在する場合はそれも渡す
					effects = this:GetEffects( sTarget.id, playerId, 12 )

					-- 対象の名前
					targetName = sTarget.name

					-- エネミーのレベルを取得する
					level = nil
					if( color >= 3 and color <= 5 ) then
						-- ノートリアスモンスターの場合は名前にランク文字列を付与する
						if( Nms[ targetName ] ~= nil ) then
							targetName = targetName .. ' ' .. Nms[ targetName ]
						end
						-- レベルを表示するのはエネミーのみ
						level = this:GetLevel( sTarget.index )
					end
	
					-- サブターゲットゲージの表示を設定する
					UI:ShowST( targetName, level, sTarget.hpp, color, isSameTarget, effects )

					stVisible = true

					-- バフ効果情報からターゲットを削除
					if( sTarget.hpp == 0 and this.effectiveTargets[ sTarget.id ] ~= nil ) then
						this.effectiveTargets[ sTarget.id ] = nil
					end
				end
			end
		end

		if( mtVisible == false and this.mtVisible == true ) then
			UI:HideMT()	-- メインターゲットゲージを消す
		end
		this.mTarget   = mTarget
		this.mtVisible = mtVisible

		if( stVisible == false and this.stVisible == true ) then
			UI:HideST()	-- サブターゲットゲージを消す
		end
		this.sTarget   = sTarget
		this.stVisible = stVisible

		-------------------------------------------------------
		-- スキャンが必要であれば実行する
		this:Scan()

		-- スキャン中の場合はマークを表示する
		if( this.scanningUpdateTime >  0 ) then
			local time = os.clock()
			if( ( time - this.scanningUpdateTime ) <  1 ) then
				UI:ShowScanning( time - this.scanningActiveTime )
			else
				-- スキャン終了
				UI:HideScanning()

				this.levelTable = this.levelTableWorks ;
				this.levelTableWorks = {}

				this.scanningUpdateTime = 0
				this.scanningActiveTime = 0
			end
		end
	end)

	-- コマンド実行時のイベントを登録する
	windower.register_event( "addon command", function( command, arg1 )
		if( this:Display() == false ) then
			return	-- 準備が整っていない
		end
		-----------------------------------

		if( command == 'help' or command == 'h' ) then
			local t = {}

			t[ #t + 1 ] = _addon.name .. " " .. "Version " .. _addon.version
			t[ #t + 1 ] = "  <コマンド> 省略[" .. _addon.commands[ 1 ] .. "]" 
			t[ #t + 1 ] = "     " .. _addon.command .. " r :位置の初期化"
			t[ #t + 1 ] = "     " .. _addon.command .. " l :位置の変更禁止"
			t[ #t + 1 ] = "     " .. _addon.command .. " u :位置の変更許可"
			t[ #t + 1 ] = "　"
			
			for tk, tv in pairs( t ) do
				PrintFF11( tv )
			end

		elseif command == 'r' then
			UI:ResetPosition()
			UI:ApplyPosition()
			Save()
			PrintFF11( "位置を初期化しました。" )
		elseif command == 'l' then
			UI:SetDraggable( false )
			Save()
			PrintFF11( "位置の変更を禁止しました。" )
		elseif command == 'u' then
			UI:SetDraggable( true )
			Save()
			PrintFF11( "位置の変更を許可しました。" )
		elseif command == 'c' then

			local mobIds = nil
			local mobs = windower.ffxi.get_mob_array()
			local exist = false
			if( mobs ~= nil ) then
				mobIds = {}
				for _, mob in pairs( mobs ) do
					mobIds[ #mobIds + 1 ] = mob.id

					print( "id[" .. mob.id .."]" .. mob.index )
					if( arg1 ~= nil and tostring( mob.id ) == tostring( arg1 ) ) then
						print( "hit" )
						exist = true
					end
				end

				print( "mob " .. #mobIds .. " exist " .. tostring( exist ) )
			end
		elseif command == 's' then
			this:Scan()
		end
	end)

	-- マウス操作時のイベントを登録する
	windower.register_event( "mouse", function( type, x, y, delta, blocked )
		if( this:Display() == false ) then
			return	-- 準備が整っていない
		end
		-----------------------------------

		if( UI:ProcessDragging( type ) == true ) then
			Save()	-- 位置に変更があったので保存する
		end
	end)
end

-----------------------------------------------------------------------

addon:RegisterEvents()		-- 最後にイベント登録を実行する

-- 設定のセーブを行う
function Save()
	Config.save( Settings )
end

-- チャットログに文字列を出力する
function PrintFF11( text )
	if( text == nil or #text == 0 ) then return end
	windower.add_to_chat( 207,  windower.to_shift_jis( text ) )
end